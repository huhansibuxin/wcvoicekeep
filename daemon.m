//
//  wcvoicekeep daemon  (v1.8.7)
//
//  目标：让 WeChat Keyboard (Wetype, com.tencent.wetype) 主 App 在注销/重启后
//  能在后台被无头拉起一次，让 dylib 用原生 PiP standby 接住（见 Tweak.xm）。
//
//  === 架构（架构同 v1.8.0，本文件仅修 bug） ===
//    dylib(Tweak.xm, TF 注入主 App) : 监听 DidFinishLaunching / DidBecomeActive
//                                     / 达尔文通知 com.wcvoicekeep.pip.trigger，
//                                     任一发生就建立 PiP standby。
//    daemon(本文件, LaunchDaemon)   : RunAtLoad 自动起 → 拉 Wetype 一次 → 发
//                                     达尔文通知给 dylib 兜底建 PiP。
//
//  === v1.8.2 修复（根因） ===
//  v1.8.1 用 dlopen SpringBoardServices + dlsym "SBSLaunchApplicationWithIdentifier"。
//  该函数签名在 iOS 14+ 已变(原两参 Boolean suspended -> 新版本 enum flags)，
//  iOS 16 上 dlsym 返回 NULL，调用 NULL function pointer -> SIGSEGV -> 进程 exit -9。
//  所以 v1.8.1 实测"daemon 没生效"=启动即段错误自杀，跟 launchctl 激活无关。
//
//  修复：用 ObjC runtime 拿 LSApplicationWorkspace.defaultWorkspace，调
//  openApplicationWithBundleID:active: (Bool)。iOS 13+ 名字稳定、不会 SIGSEGV。
//  第二参 active=NO 本意是后台拉起，但【实测 iOS 16 照样弹 UI】——active:NO 只是
//  "不抢已运行 App 的前台"，新 App launch 时界面仍渲染。所以这条路做不到真无头。
//
//  === v1.8.7 修复（真无头启动）===
//  要"无头/后台启动不显 UI"（同支付宝静默推送唤醒主 App 进后台），正确做法是
//  SpringBoardServices 私有 API：
//      int SBSLaunchApplicationWithIdentifier(CFStringRef bid, int flags);
//  flags = 1 (SBSApplicationLaunchFlagBackground，sbutils -b 源码佐证 flags|=1)
//  -> 主 App 收到 didFinishLaunching 即进 background，绝不上前台、不渲染 UI，
//     dylib 在后台收到通知照样建 PiP standby（PiP 在 background 也能持续）。
//  需要 entitlement：com.apple.springboard.launchapplications（entitlements.plist 已有）。
//  iOS 16 上 SpringBoardServices 磁盘二进制被合进 dyld shared cache，dlopen 可能失败，
//  所以 SBS 不可用时回退 LSA active:NO（仅兜底，会带 UI）。
//
//  进程存在检测也由 SBS 改 proc_listpids，避免 dlsym 失败时拿不到 pid 误判"未跑"。
//
//  编译：Makefile 的 TOOL_NAME=wcvoicekeep (rootless -> /var/jb/usr/bin/wcvoicekeep)
//        + entitlements.plist 中的 com.apple.springboard.launchapplications (LSApplicationWorkspace
//        在 daemon 上下文仍受 entitlement 管控，缺这个会被拒)。
//
#include <Foundation/Foundation.h>
#include <objc/message.h>   // objc_msgSend (强转调 active: BOOL 参数)
#include <dlfcn.h>          // dlopen LSApplicationWorkspace 所在 framework
#include <sys/sysctl.h>
#include <sys/param.h>      // PATH_MAX
#include <sys/proc.h>       // struct kinfo_proc / KERN_PROC_*
#include <stdlib.h>
#include <string.h>

// notify.h 在 theos iOS SDK 16.5 路径里默认找不全 - 手动声明 Darwin 通知 API
// 而不依赖 <notify.h>。这是私有 API 但 iOS 13+ 名/segnature 都稳定。
extern uint32_t notify_post(const char *name);

// ===== 配置 =====
static NSString *const kTargetBundleID = @"com.tencent.wetype";
static const char    *const kTriggerName = "com.wcvoicekeep.pip.trigger"; // 与 Tweak.xm 一致
static const int    kBootDelaySec     = 10;        // 开机等 SpringBoard
static const int    kCheckIntervalSec = 60;        // 守护轮询
static const int    kRelLaunchDelaySec = 6;        // 拉起后等 dylib 起来
static NSString *const kLogPath = @"/var/mobile/wcvoicekeep.daemon.log";

// ===== 无头启动：SBS 后台 flag=1（首选），LSA active:NO（兜底）=====
// SBS background flag=1 = 真后台启动（不显 UI）。LSA active:NO 仅兜底（会带 UI）。
@interface LSAppWorkspaceShim : NSObject
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(id)arg1 active:(BOOL)arg2;
@end

// ===== 工具：append 写日志(原子写避免半行) =====
static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@][daemon] %@\n", [NSDate date], msg];
    NSLog(@"[WCVK-daemon] %@", msg);
    // 镜像到 stderr → launchd StandardErrorPath(/var/mobile/wcvoicekeep.daemon.err)
    // 进程被 SIGKILL/SIGSEGV/launchd throttle 时不至于丢全部上下文
    fprintf(stderr, "%s", [line UTF8String]); fflush(stderr);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [[NSData data] writeToFile:kLogPath atomically:YES]; // touch
        fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    @try { [fh closeFile]; } @catch (NSException *e) {}
}

// ===== 进程存在性：通过 sysctl(KERN_PROC_ALL) + kinfo_proc.kp_proc.p_comm =====
// 不用 libproc.h (Theos iOS SDK 找不到头)，手写 sysctl 路径稳如老狗。
// 主 App 进程名 "wetype"（<=16 字节，正常），扩展进程名 "wxkb" 或 "WxKeyboard"，
// 模糊匹配任一即认为 Wetype 在跑。
static BOOL isAppRunning(NSString *bundleID) {
    (void)bundleID;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return NO;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return NO;
    if (sysctl(mib, 4, procs, &sz, NULL, 0) != 0) { free(procs); return NO; }
    int n = (int)(sz / sizeof(struct kinfo_proc));
    BOOL found = NO;
    for (int i = 0; i < n; i++) {
        const char *comm = procs[i].kp_proc.p_comm;
        if (comm[0] == 0) continue;
        if (strstr(comm, "wetype") != NULL ||
            strstr(comm, "WxKeyboard") != NULL ||
            strstr(comm, "wxkb") != NULL) { found = YES; break; }
    }
    free(procs);
    return found;
}

// ===== 关键：daemon 是独立进程，默认不链接 MobileCoreServices/LSApplicationWorkspace
// framework，NSClassFromString(@"LSApplicationWorkspace") 会返回 NULL → 之前的
// [FATAL] class not found。必须显式 dlopen 让 dyld 把 ObjC 类注册进 runtime。
// iOS 16 上 LSApplicationWorkspace 在 MobileCoreServices.framework（旧）里，
// 同时 iOS 14+ 也独立成 PrivateFrameworks/LSApplicationWorkspace.framework，
// 两处都试，谁先注册成功就用谁的。
static void ensureLSFrameworkLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *cands[] = {
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
            "/System/Library/PrivateFrameworks/LSApplicationWorkspace.framework/LSApplicationWorkspace",
            NULL
        };
        for (int i = 0; cands[i]; i++) {
            void *h = dlopen(cands[i], RTLD_LAZY | RTLD_GLOBAL);
            if (h) LOG(@"dlopen %s OK", cands[i]);
            else  LOG(@"dlopen %s FAILED: %s", cands[i], dlerror());
        }
    });
}

// ===== SBS 后台无头启动（首选）=====
// SpringBoardServices 私有 API：int SBSLaunchApplicationWithIdentifier(CFStringRef, int)
// flags=1 (SBSApplicationLaunchFlagBackground) = 真后台启动，不显 UI、不进前台。
// 需要 com.apple.springboard.launchapplications entitlement（entitlements.plist 已有）。
// iOS 16 上该 framework 二进制被合进 dyld shared cache，dlopen 可能失败 -> 走 LSA 兜底。
static int (*g_SBSLaunch)(CFStringRef, int) = NULL;
static BOOL sbsReady(void) {
    static dispatch_once_t once; static void *h = NULL; static BOOL ok = NO;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                   RTLD_LAZY);
        if (h) {
            g_SBSLaunch = dlsym(h, "SBSLaunchApplicationWithIdentifier");
            if (g_SBSLaunch) {
                // 部分版本需先建立 SpringBoard server 端口，建立即可（返回值不用）
                void (*portfn)(void) = dlsym(h, "SBSSpringBoardServerPort");
                if (portfn) portfn();
                ok = YES;
                LOG(@"SBS ready (SpringBoardServices loaded, SBSLaunchApplicationWithIdentifier found)");
            } else {
                LOG(@"SBS dlsym SBSLaunchApplicationWithIdentifier FAILED: %s", dlerror());
            }
        } else {
            LOG(@"SBS dlopen FAILED: %s", dlerror());
        }
    });
    return ok;
}

// ===== 核心：拉 Wetype 到 background（真无头，不显 UI）=====
static void launchBackground(void) {
    LOG(@"launchBackground called");

    // 首选：SBS 后台无头启动（flag=1 = SBSApplicationLaunchFlagBackground）
    if (sbsReady() && g_SBSLaunch) {
        int flags = 1; // SBSApplicationLaunchFlagBackground（sbutils -b 源码佐证 flags|=1）
        int r = g_SBSLaunch((__bridge CFStringRef)kTargetBundleID, flags);
        LOG(@"SBSLaunchApplicationWithIdentifier(%@, Background=1) -> %d (0=ok)", kTargetBundleID, r);
        if (r == 0) { LOG(@"SBS background launch OK - no UI should appear"); return; }
        LOG(@"SBS returned non-zero, fallback to LSA");
    }

    // 兜底：LSA active:NO（iOS16 实测会带 UI，仅兜底用）
    ensureLSFrameworkLoaded();   // 先确保 framework 已加载，类才找得到
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls == Nil) {
        LOG(@"[FATAL] LSApplicationWorkspace class not found even after dlopen - check framework path");
        return;
    }
    id ws = nil;
    @try { ws = [cls performSelector:@selector(defaultWorkspace)]; }
    @catch (NSException *e) { LOG(@"[FATAL] defaultWorkspace threw: %@", e); return; }
    if (ws == nil) { LOG(@"[FATAL] defaultWorkspace returned nil"); return; }

    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:active:");
    if (![ws respondsToSelector:sel]) {
        // 极旧版本兜底：openApplicationWithBundleID:
        sel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (![ws respondsToSelector:sel]) {
            LOG(@"[FATAL] LSApplicationWorkspace has no openApplicationWithBundleID selector");
            return;
        }
        @try {
            BOOL ok = (BOOL)[ws performSelector:sel withObject:kTargetBundleID];
            LOG(@"openApplicationWithBundleID: -> %d", ok);
        } @catch (NSException *e) { LOG(@"[FATAL] old path threw: %@", e); }
        return;
    }

    // active=NO = 不抢前台（但新 App launch 仍会渲染 UI，iOS16 实测）。
    // 用 objc_msgSend 强转明确传 BOOL，避免 performSelector:withObject:
    // 把 CFBoolean 指针当 BOOL 塞进参数寄存器造成错位。
    BOOL ok = NO;
    @try {
        BOOL (*impl)(id, SEL, id, BOOL) = (BOOL(*)(id, SEL, id, BOOL))objc_msgSend;
        ok = impl(ws, sel, kTargetBundleID, NO);
    } @catch (NSException *e) { LOG(@"[FATAL] launch threw: %@", e); return; }
    LOG(@"openApplicationWithBundleID:%@ active:NO -> ret=%d (UI may appear - SBS unavailable)",
        kTargetBundleID, ok);
}

// ===== 触发：发 Darwin 通知让 dylib 兜底建 PiP =====
static void postTrigger(void) {
    uint32_t st = notify_post(kTriggerName);
    LOG(@"notify_post(%s) -> %u (0=ok)", kTriggerName, st);
}

// ===== 主循环：定期检查，拉起后等 dylib 起来再发触发 =====
static void checkAndLaunch(void) {
    if (isAppRunning(kTargetBundleID)) {
        LOG(@"%@ alive -> only trigger dylib", kTargetBundleID);
        postTrigger();
        return;
    }
    LOG(@"%@ NOT running -> background launch", kTargetBundleID);
    launchBackground();
    // 等 dylib 接 didFinishLaunching 建 PiP（最坏兜底是触发通知）
    for (int i = 0; i < kRelLaunchDelaySec; i++) {
        sleep(1);
        if (isAppRunning(kTargetBundleID)) {
            LOG(@"%@ up after %ds, firing trigger", kTargetBundleID, i+1);
            postTrigger();
            return;
        }
    }
    LOG(@"%@ did NOT come up in %ds - will retry next tick",
        kTargetBundleID, kRelLaunchDelaySec);
}

int main(int argc, char *argv[]) {
    // 早期 stderr（不依赖 Foundation/ObjC runtime）——
    // launchd 任何阶段拒收(进程类型/entitlement/签名/sandbox)都能立刻看到，
    // 否则后面 LOG 走 NSLog + 文件句柄,启动被秒拒时来不及写任何东西。
    fprintf(stderr, "[WCVK-DAEMON] main() entered pid=%d uid=%d argv0=%s\n",
            getpid(), getuid(), (argc > 0 && argv[0]) ? argv[0] : "?");
    fflush(stderr);

    @autoreleasepool {
        LOG(@"==== daemon boot ====");
        LOG(@"pid=%d uid=%d argv0=%s", getpid(), getuid(), argv[0] ?: "?");
        LOG(@"target=%@ trigger=%s", kTargetBundleID, kTriggerName);
        LOG(@"log=%@", kLogPath);

        // 初次启动：给 SpringBoard 时间
        LOG(@"sleeping %ds for SpringBoard...", kBootDelaySec);
        sleep(kBootDelaySec);
        @autoreleasepool { checkAndLaunch(); }

        // 守护循环
        while (1) {
            sleep(kCheckIntervalSec);
            @autoreleasepool { checkAndLaunch(); }
        }
    }
    return 0;
}
