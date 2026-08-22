//
//  wcvoicekeep daemon  (v1.9.1)
//
//  目标：让 WeChat Keyboard (Wetype, com.tencent.wetype) 主 App 在注销/重启后
//  自动被前台预热一次，建起原生 PiP standby 并自动退后台自保活（见 Tweak.xm）。
//
//  === 架构 ===
//    dylib(Tweak.xm, TF 注入主 App) : 监听 DidFinishLaunching / DidBecomeActive
//                                     / 达尔文通知 com.wcvoicekeep.pip.trigger；
//                                     前台激活时建 PiP standby；预热模式下建完自动退后台。
//    daemon(本文件, LaunchDaemon)   : RunAtLoad 自动起 → 前台预热 Wetype 一次（带
//                                     --wcvk-warmup 参数）→ 之后 60s 轮询看护。
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
//  === v1.8.7 修复（无头启动，v1.9.0 弃用改预热）===
//  SBSLaunchApplicationWithIdentifier(CFStringRef, int flags)，flags=1=Background 可无头拉起。
//  但实测：后台拉起的 App 里 startPictureInPicture 被系统硬拒（UIScene 必须
//  ForegroundActive，AVKit 错误 -1001），dylib 建不起 PiP -> 无保活凭证 -> App 挂起被杀。
//  v1.8.8 音频保活（静音循环）能保活但耗 media 服务（老板否决）。
//
//  === v1.9.0 架构（最终，老板拍板）===
//  唯一可行 = 开机后前台预热一次：
//    1) 前台拉起让 App 激活出 UI（闪 ~0.5s，带 --wcvk-warmup 参数）
//    2) dylib 立即建 PiP（isActive=1）
//    3) dylib 判定预热 -> [[UIApplication suspend]] 自动退后台
//    4) PiP 常驻后台 = 自保活凭证（无 media 服务、0 CPU），点语音按钮不跳转
//  预热节流：成功拉起后 15min 内不重复（防反复闪屏）；锁屏期失败不记录，每 60s 重试。
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
#include <time.h>           // time() 预热节流
#include <signal.h>         // SIGKILL

// notify.h 在 theos iOS SDK 16.5 路径里默认找不全 - 手动声明 Darwin 通知 API
// 而不依赖 <notify.h>。这是私有 API 但 iOS 13+ 名/签名都稳定。
extern uint32_t notify_post(const char *name);
extern uint32_t notify_register_dispatch(const char *name, int *out_token,
                                         dispatch_queue_t queue, void (^handler)(int));
extern uint32_t notify_get_state(int token, uint64_t *state);

#define SBS_PATH "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"

// ===== 配置 =====
static NSString *const kTargetBundleID = @"com.tencent.wetype";
static const char    *const kTriggerName = "com.wcvoicekeep.pip.trigger"; // 与 Tweak.xm 一致
static const char    *const kPipBuiltName = "com.wcvoicekeep.pip.built";  // dylib->daemon：PiP 已建
static const int    kBootDelaySec     = 3;        // 开机等 SpringBoard（原 10s，尽早预热）
static const int    kCheckIntervalSec = 60;       // 守护轮询
static const int    kFastRetrySec     = 5;        // 预热快循环间隔（锁屏期重试）
static const int    kPipWaitTimeoutSec = 15;      // 等 dylib 报 pip.built 超时
static const int    kKillStaleSec     = 25;       // 进程在跑但迟迟无 pip.built -> kill 重试（锁屏僵尸）
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

// ===== 预热：前台拉起（激活出 UI）→ dylib 建 PiP → 自动退后台 =====
// v1.9.0 架构（老板拍板）：后台起 PiP 被系统硬限制（UIScene 必须 ForegroundActive，
// AVKit 错误 -1001 铁证，无私有 API 可绕）；音频保活又耗 media 服务（已否决）。
// 唯一可行 = 开机后前台预热一次：
//   1) 前台拉起让 App 激活出 UI（闪 ~0.5s）
//   2) dylib 立即建 PiP（isActive=1）
//   3) dylib 判定预热（--wcvk-warmup 参数）-> [[UIApplication suspend]] 自动退后台
//   4) PiP 常驻后台 = 自保活凭证（无 media 服务、0 CPU），点语音按钮不跳转
// 首选 SBSLaunchApplicationForDebugging 带 --wcvk-warmup 参数；
// 兜底 SBS flag=0 前台激活 / LSA active:YES。
static time_t gLastWarmup = 0;
static const time_t kWarmupMinInterval = 900; // 15min：成功拉起后节流，防反复闪屏

static BOOL warmupForeground(void) {
    LOG(@"warmupForeground called");
    // (1) 首选：SBSLaunchApplicationForDebugging 带 --wcvk-warmup 参数（dylib 据此自动退后台）
    if (sbsReady() && g_SBSLaunch) {
        static int (*sbsDbg)(CFStringRef, CFURLRef, CFArrayRef, CFDictionaryRef,
                             CFStringRef, CFStringRef, char) = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                             RTLD_LAZY);
            if (h) sbsDbg = dlsym(h, "SBSLaunchApplicationForDebugging");
        });
        if (sbsDbg) {
            NSArray *args = @[@"--wcvk-warmup"];
            int r = sbsDbg((__bridge CFStringRef)kTargetBundleID, NULL,
                           (__bridge CFArrayRef)args, NULL, NULL, NULL, 0);
            LOG(@"warmup SBSLaunchApplicationForDebugging(--wcvk-warmup) -> %d (0=ok)", r);
            if (r == 0) return YES;
            LOG(@"warmup debug-launch failed(%d), fallback", r);
        } else {
            LOG(@"warmup SBSLaunchApplicationForDebugging dlsym FAILED, fallback");
        }
        // (2) 兜底：SBS 普通前台激活（flag=0）；dylib 用「启动后<8s 且刚建 PiP」启发式判定
        int r = g_SBSLaunch((__bridge CFStringRef)kTargetBundleID, 0);
        LOG(@"warmup SBSLaunchApplicationWithIdentifier(flag=0) -> %d (0=ok)", r);
        if (r == 0) return YES;
    }
    // (3) 最后兜底：LSA active:YES 前台
    ensureLSFrameworkLoaded();
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls == Nil) { LOG(@"[FATAL] LSApplicationWorkspace class not found"); return NO; }
    id ws = nil;
    @try { ws = [cls performSelector:@selector(defaultWorkspace)]; }
    @catch (NSException *e) { LOG(@"[FATAL] defaultWorkspace threw: %@", e); return NO; }
    if (ws == nil) { LOG(@"[FATAL] defaultWorkspace nil"); return NO; }
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:active:");
    if (![ws respondsToSelector:sel]) { LOG(@"[FATAL] no openApplicationWithBundleID:active:"); return NO; }
    BOOL ok = NO;
    @try {
        BOOL (*impl)(id, SEL, id, BOOL) = (BOOL(*)(id, SEL, id, BOOL))objc_msgSend;
        ok = impl(ws, sel, kTargetBundleID, YES);
    } @catch (NSException *e) { LOG(@"[FATAL] LSA launch threw: %@", e); return NO; }
    LOG(@"warmup LSA openApplicationWithBundleID:active:YES -> %d", ok);
    return ok;
}

// ===== 触发：发 Darwin 通知让 dylib 兜底建 PiP =====
static void postTrigger(void) {
    uint32_t st = notify_post(kTriggerName);
    LOG(@"notify_post(%s) -> %u (0=ok)", kTriggerName, st);
}

// ===== v1.9.1 状态机：dylib 反向通知 pip.built + 屏幕状态 =====
// 为什么：isAppRunning 只能判断"进程在"，区分不了"带着 PiP 活着"还是"锁屏期起的僵尸"。
// 让 dylib 建好 PiP 后反向发 Darwin 通知 com.wcvoicekeep.pip.built，daemon 才知道预热真成功。
static BOOL gPipUp = NO;      // dylib 确认 PiP 已建（自保活生效）
static BOOL gScreenBlank = NO; // 屏幕熄灭（hasBlankedScreen 通知）
static time_t gWarmupLaunchTs = 0;

static void registerNotifs(void) {
    // pip.built：走后台队列（main 线程在 sleep 轮询，主队列 block 不会执行）
    static int pipToken = 0;
    notify_register_dispatch(kPipBuiltName, &pipToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t) {
        gPipUp = YES;
        gLastWarmup = time(NULL);
        LOG(@"PIP.BUILT received -> warmup success, self keep-alive active");
    });
    // 屏幕状态：1=熄屏（可无感重预热），0=亮屏（绝不中途闪）
    static int scrToken = 0;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &scrToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t) {
        uint64_t st = 0;
        notify_get_state(scrToken, &st);
        gScreenBlank = (st == 1);
        LOG(@"screen %@ (state=%llu)", gScreenBlank ? @"BLANK" : @"UNBLANK", (unsigned long long)st);
    });
    LOG(@"notifs registered (pip.built + hasBlankedScreen)");
}

// 杀进程：锁屏期 SBS 拉起可能只起进程不激活（不建 PiP），杀掉让下轮重试激活
static void killApp(void) {
    static int (*pidFn)(CFStringRef, pid_t *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen(SBS_PATH, RTLD_LAZY);
        if (h) pidFn = dlsym(h, "SBSProcessIDForDisplayIdentifier");
    });
    if (!pidFn) { LOG(@"killApp: SBSProcessIDForDisplayIdentifier unavailable"); return; }
    pid_t pid = 0;
    if (pidFn((__bridge CFStringRef)kTargetBundleID, &pid) == 0 && pid > 0) {
        kill(pid, SIGKILL);
        LOG(@"kill %@ pid=%d (SIGKILL) - retry activation next cycle", kTargetBundleID, (int)pid);
    }
}

// 一次预热尝试：没起 -> 前台拉起等 pip.built；起了但超时无 pip.built -> kill 重试
static void warmupOnce(void) {
    if (gPipUp) return;
    if (isAppRunning(kTargetBundleID)) {
        if (time(NULL) - gWarmupLaunchTs > kKillStaleSec) killApp();
        return;
    }
    gWarmupLaunchTs = time(NULL);
    LOG(@"%@ NOT running -> foreground warmup (attempt)", kTargetBundleID);
    warmupForeground();
    // 等 dylib 报 pip.built（非阻塞轮询，最多 kPipWaitTimeoutSec 秒）
    for (int i = 0; i < kPipWaitTimeoutSec; i++) {
        if (gPipUp) return;
        sleep(1);
    }
    LOG(@"%@ no pip.built in %ds - will retry", kTargetBundleID, kPipWaitTimeoutSec);
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
        LOG(@"target=%@ trigger=%s pipBuilt=%s", kTargetBundleID, kTriggerName, kPipBuiltName);
        LOG(@"log=%@", kLogPath);

        registerNotifs();
        LOG(@"sleeping %ds for SpringBoard...", kBootDelaySec);
        sleep(kBootDelaySec);

        // 快速预热循环：尽早拉起（锁屏期每 ~20s 重试，解锁后 ~5s 内闪屏建 PiP）
        while (!gPipUp) {
            @autoreleasepool { warmupOnce(); }
            if (gPipUp) break;
            sleep(kFastRetrySec);
        }
        LOG(@"warmup complete (gPipUp=YES) -> entering 60s watch");

        // 守护循环
        while (1) {
            sleep(kCheckIntervalSec);
            @autoreleasepool {
                if (isAppRunning(kTargetBundleID)) {
                    LOG(@"%@ alive -> only trigger dylib", kTargetBundleID);
                    postTrigger();
                    continue;
                }
                // App 死了：
                //  - 屏幕亮 -> 绝不自动重预热（老板要求：前台用着别闪），降级到下次注销
                //  - 屏幕灭 -> 静默重预热（无感），带 15min 节流
                gPipUp = NO;
                time_t now = time(NULL);
                if (gScreenBlank && now - gLastWarmup >= kWarmupMinInterval) {
                    LOG(@"%@ died & screen BLANK -> silent re-warm", kTargetBundleID);
                    while (!gPipUp) {
                        @autoreleasepool { warmupOnce(); }
                        if (gPipUp) break;
                        sleep(kFastRetrySec);
                    }
                } else {
                    LOG(@"%@ died & screen ON -> NO auto re-warm (avoid mid-session flash); degraded until respring", kTargetBundleID);
                }
            }
        }
    }
    return 0;
}
