//
//  wcvoicekeep daemon  (v1.9.30)
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
#include <fcntl.h>          // v1.9.23：日志 3M 上限（open O_TRUNC）
#include <sys/stat.h>       // v1.9.23：stat 日志大小

// notify.h 在 theos iOS SDK 16.5 路径里默认找不全 - 手动声明 Darwin 通知 API
// 而不依赖 <notify.h>。这是私有 API 但 iOS 13+ 名/签名都稳定。
extern uint32_t notify_post(const char *name);
extern uint32_t notify_register_dispatch(const char *name, int *out_token,
                                         dispatch_queue_t queue, void (^handler)(int));
extern uint32_t notify_get_state(int token, uint64_t *state);

#define SBS_PATH "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"

// ===== 配置 =====
static NSString *const kTargetBundleID = @"com.tencent.wetype";
static NSString *const kWechatBundleID = @"com.tencent.xin"; // 注销后错开无头拉起（老板要求）
static const char    *const kTriggerName = "com.wcvoicekeep.pip.trigger"; // 与 Tweak.xm 一致
static const char    *const kPipBuiltName = "com.wcvoicekeep.pip.built";  // dylib->daemon：PiP 已建
static const int    kBootDelaySec     = 1;        // v1.9.20：1s（原 3s），注销后尽早开始预热
static const int    kCheckIntervalSec = 60;       // 守护轮询
static const int    kFastRetrySec     = 5;        // 预热快循环间隔（锁屏期重试）
static const int    kPipWaitTimeoutSec = 15;      // 等 dylib 报 pip.built 超时
static const int    kKillStaleSec     = 25;       // 进程在跑但迟迟无 pip.built -> kill 重试（锁屏僵尸）
static NSString *const kLogPath = @"/var/mobile/wcvoicekeep.daemon.log";

// 前向声明：maybeWarmWechat / reWarm / watchWechat 定义在 registerNotifs 之后，但回调里要用
static void maybeWarmWechat(void);
static void reWarm(void);
static void watchWechat(void);
static int taskSuspendCount(int pid); // v1.9.15：warmupOnce(361) 在定义(465)之前使用
static BOOL otherAudioPlaying(void);  // v1.9.21：pip.lost 回调(364)在定义(551)之前使用

// ===== 无头启动：SBS 后台 flag=1（首选），LSA active:NO（兜底）=====
// SBS background flag=1 = 真后台启动（不显 UI）。LSA active:NO 仅兜底（会带 UI）。
@interface LSAppWorkspaceShim : NSObject
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(id)arg1 active:(BOOL)arg2;
@end

// ===== 工具：append 写日志(原子写避免半行) =====
// v1.9.23：日志上限 3M（kLogPath + stderr 重定向文件），每 30s 检查一次超限清空
static void TrimDaemonLogs(void) {
    static time_t lastCheck = 0;
    time_t now = time(NULL);
    if (now - lastCheck < 30) return;
    lastCheck = now;
    @autoreleasepool {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:kLogPath error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] > 3ull * 1024 * 1024) {
            [[NSData data] writeToFile:kLogPath atomically:YES]; // 清空
        }
    }
    const char *errPath = "/var/log/wcvoicekeep.daemon.err";
    struct stat est;
    if (stat(errPath, &est) == 0 && est.st_size > 3ll * 1024 * 1024) {
        int fd = open(errPath, O_WRONLY | O_TRUNC);
        if (fd >= 0) close(fd);
    }
}
static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@][daemon] %@\n", [NSDate date], msg];
    NSLog(@"[WCVK-daemon] %@", msg);
    // 镜像到 stderr → launchd StandardErrorPath(/var/log/wcvoicekeep.daemon.err)
    // 进程被 SIGKILL/SIGSEGV/launchd throttle 时不至于丢全部上下文
    fprintf(stderr, "%s", [line UTF8String]); fflush(stderr);
    TrimDaemonLogs(); // v1.9.23：3M 上限
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
// 通用：进程表里是否有精确匹配 comm 的进程（v1.9.7 抽出来给 wetype/微信共用）
static BOOL procExists(const char *want) {
    if (!want || !want[0]) return NO;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return NO;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return NO;
    if (sysctl(mib, 4, procs, &sz, NULL, 0) != 0) { free(procs); return NO; }
    int n = (int)(sz / sizeof(struct kinfo_proc));
    BOOL found = NO;
    for (int i = 0; i < n; i++) {
        // v1.9.4：必须 strcmp 精确匹配——键盘扩展进程名 wxkb_plugin 含 wxkb 子串，
        // strstr 会把它误判成"活着"（主 App 被杀也不重拉）。排除 *_plugin。
        if (strcmp(procs[i].kp_proc.p_comm, want) == 0) { found = YES; break; }
    }
    free(procs);
    return found;
}

// wetype 主 App 进程名：wxkb（扩展进程 wxkb_plugin 不算）
static BOOL isAppRunning(NSString *bundleID) {
    (void)bundleID;
    return procExists("wxkb") || procExists("wetype") || procExists("WxKeyboard");
}

// v1.9.13：返回匹配 comm 的第一个进程 pid（找不到 -1）。wetype 主 App = wxkb
static int procPid(const char *want) {
    if (!want || !want[0]) return -1;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &sz, NULL, 0) != 0) { free(procs); return -1; }
    int n = (int)(sz / sizeof(struct kinfo_proc));
    int pid = -1;
    for (int i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, want) == 0) { pid = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return pid;
}

// 微信主进程名：WeChat
// v1.9.17：官方微信检测改为「一次性缓存容器路径 + proc_pidpath 轻量判定」。
// 不能用 procExists("WeChat")——设备两个微信（官方 com.tencent.xin + 企业
// com.tencent.qy.xin）主进程名都叫 WeChat，企业微信在跑会误判官方微信活着。
// v1.9.16 的 allApplications 每次 tick 遍历太重 -> 内存暴涨被 jetsam 杀 14 次
// （last exit reason = JETSAM_REASON_MEMORY_PERPROCESSLIMIT）-> 微信看护失效。
// 现改为：启动时用 LSApplicationWorkspace 拿一次官方微信容器路径（一次性开销），
// 之后 isWechatRunning 纯 sysctl + proc_pidpath 路径前缀匹配（轻量、零内存增长）。
// theos SDK 缺 libproc.h，手写声明（libproc 系统库符号稳定）。
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
static char gWechatPathPrefix[PATH_MAX] = {0}; // 官方微信容器路径前缀（如 .../720ADACF-.../）
// v1.9.18：文件系统扫描找官方微信容器——读每个 WeChat.app/Info.plist 的
// CFBundleIdentifier，匹配 com.tencent.xin 即记录其容器路径。
// 不用 LSApplicationWorkspace（v1.9.17 实测 allApplications 遍历拿不到/不触发，
// container cached 日志=0，fallback 回"任意 WeChat"-> 企业微信顶替 bug 复活）。
static void cacheWechatPath(void) {
    if (gWechatPathPrefix[0]) return; // 只做一次
    NSArray *dirs = [[NSFileManager defaultManager]
                     contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
    for (NSString *uuid in dirs) {
        NSString *plistPath = [NSString stringWithFormat:
            @"/var/containers/Bundle/Application/%@/WeChat.app/Info.plist", uuid];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if ([info[@"CFBundleIdentifier"] isEqualToString:kWechatBundleID]) {
            NSString *container = [NSString stringWithFormat:
                @"/var/containers/Bundle/Application/%@/", uuid];
            strlcpy(gWechatPathPrefix, [container UTF8String], PATH_MAX);
            LOG(@"wechat(xin) container cached: %@", container);
            return;
        }
    }
    LOG(@"wechat(xin) container NOT FOUND in filesystem scan");
}
static BOOL isWechatRunning(void) {
    cacheWechatPath();
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return NO;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return NO;
    if (sysctl(mib, 4, procs, &sz, NULL, 0) != 0) { free(procs); return NO; }
    int n = (int)(sz / sizeof(struct kinfo_proc));
    BOOL found = NO;
    for (int i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "WeChat") != 0) continue;
        if (gWechatPathPrefix[0]) {
            char pathbuf[PATH_MAX];
            int len = (int)proc_pidpath(procs[i].kp_proc.p_pid, pathbuf, sizeof(pathbuf));
            if (len > 0 && strncmp(pathbuf, gWechatPathPrefix, strlen(gWechatPathPrefix)) == 0) { found = YES; break; }
        } else {
            found = YES; // 缓存失败 fallback：任意 WeChat 进程
            break;
        }
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
static time_t gLastWarmup = 0; // pip.built 时间戳（日志参考）

// 状态（warmupForeground 里要用，须先声明）
static BOOL gPipUp = NO;       // dylib 确认 PiP 已建（自保活生效）
static BOOL gScreenBlank = NO; // 屏幕熄灭（hasBlankedScreen 通知）
static BOOL gLocked = NO;      // v1.9.10：设备锁定（lockstate 通知，1=锁定）——锁屏拉起输入法是僵尸没 PiP
static time_t gWarmupLaunchTs = 0;

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
            // v1.9.2：息屏时带 SBSApplicationLaunchUnlockDevice(4) 亮屏唤醒预热
            char flags = gScreenBlank ? 4 : 0;
            int r = sbsDbg((__bridge CFStringRef)kTargetBundleID, NULL,
                           (__bridge CFArrayRef)args, NULL, NULL, NULL, flags);
            LOG(@"warmup SBSLaunchApplicationForDebugging(--wcvk-warmup, flags=%d) -> %d (0=ok)", (int)flags, r);
            if (r == 0) return YES;
            LOG(@"warmup debug-launch failed(%d), fallback", r);
        } else {
            LOG(@"warmup SBSLaunchApplicationForDebugging dlsym FAILED, fallback");
        }
        // (2) 兜底：SBS 前台激活（亮屏 flag=0；息屏 flag=4 亮屏唤醒）；
        //     dylib 用「启动后<8s 且刚建 PiP」启发式判定
        int flags = gScreenBlank ? 4 : 0;
        int r = g_SBSLaunch((__bridge CFStringRef)kTargetBundleID, flags);
        LOG(@"warmup SBSLaunchApplicationWithIdentifier(flags=%d) -> %d (0=ok)", flags, r);
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
    LOG(@"notify_post(%s) -> %u (0=ok)", kTriggerName, st); // 测试版：详细日志
}

// ===== v1.9.1 状态机：dylib 反向通知 pip.built + 屏幕状态 =====
// 为什么：isAppRunning 只能判断"进程在"，区分不了"带着 PiP 活着"还是"锁屏期起的僵尸"。
// 让 dylib 建好 PiP 后反向发 Darwin 通知 com.wcvoicekeep.pip.built，daemon 才知道预热真成功。
// （gPipUp / gScreenBlank / gWarmupLaunchTs 声明在 warmupForeground 之前）

static void registerNotifs(void) {
    // pip.built：走后台队列（main 线程在 sleep 轮询，主队列 block 不会执行）
    static int pipToken = 0;
    notify_register_dispatch(kPipBuiltName, &pipToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t) {
        gPipUp = YES;
        gLastWarmup = time(NULL);
        LOG(@"PIP.BUILT received -> warmup success, self keep-alive active");
    });
    // v1.9.19：pip.lost（dylib 检测 PiP 被视频顶掉）-> 立即回发 trigger 让 dylib
    // 在 scene active 下后台重建 PiP（秒级，不等 60s tick，无跳转）
    // v1.9.21：回发前查音频——微信视频 PiP 在播（有声音）时不 trigger，
    // 避免 wetype 重建抢唯一 PiP 通道顶掉微信视频 PiP（老板实测恶性循环）
    static int lostToken = 0;
    notify_register_dispatch("com.wcvoicekeep.pip.lost", &lostToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t) {
        gPipUp = NO;
        if (otherAudioPlaying()) {
            LOG(@"PIP.LOST but OTHER AUDIO playing (WeChat video PiP?) -> hold, no rebuild");
            return;
        }
        LOG(@"PIP.LOST received -> immediate re-trigger (dylib rebuilds PiP in background)");
        postTrigger();
    });
    // 屏幕状态：1=息屏，0=亮屏
    static int scrToken = 0;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &scrToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t) {
        uint64_t st = 0;
        notify_get_state(scrToken, &st);
        gScreenBlank = (st == 1);
        LOG(@"screen %@ (state=%llu)", gScreenBlank ? @"BLANK" : @"UNBLANK", (unsigned long long)st);
        watchWechat(); // 微信看护：屏幕事件也顺带查（微信无头不需激活，息屏/亮屏都拉）
        // wetype：仅亮屏且未锁定时才拉（锁屏拉起是僵尸没 PiP，老板实测）。解锁由 lockstate 回调触发。
        if (!gScreenBlank && !gLocked && !gPipUp) {
            LOG(@"screen ON & unlocked & wetype not kept-alive -> immediate re-warm");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                gPipUp = NO;
                reWarm();
                if (gPipUp) maybeWarmWechat();
            });
        }
    });

    // v1.9.10 锁屏状态：1=锁定，0=解锁。锁屏拉起输入法是僵尸（无法激活没 PiP），
    // 所以 wetype 只在解锁后重拉；微信无头拉起不受锁屏影响，照拉。
    static int lockToken = 0;
    notify_register_dispatch("com.apple.springboard.lockstate", &lockToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t) {
        uint64_t st = 0;
        notify_get_state(lockToken, &st);
        gLocked = (st == 1);
        LOG(@"lock %@ (state=%llu)", gLocked ? @"LOCKED" : @"UNLOCKED", (unsigned long long)st);
        watchWechat(); // 微信：锁屏/解锁都拉（无头不需激活）
        // 解锁瞬间：wetype 没保活 -> 立即重拉（补完注销后锁屏期没完成的预热）
        if (!gLocked && !gPipUp) {
            LOG(@"unlocked & wetype not kept-alive -> immediate re-warm");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                gPipUp = NO;
                reWarm();
                if (gPipUp) maybeWarmWechat();
            });
        }
    });
    LOG(@"notifs registered (pip.built + hasBlankedScreen + lockstate)");
}

// 杀进程：锁屏期 SBS 拉起可能只起进程不激活（不建 PiP），杀掉让下轮重试激活。
// v1.9.14：改用 procPid("wxkb") + kill——实测 SBSProcessIDForDisplayIdentifier 拿不到
// pid（静默失败），导致 zombie 分支 kill 无效、wetype 永远挂着不重建。
static void killApp(void) {
    int pid = procPid("wxkb");
    if (pid > 0) {
        kill(pid, SIGKILL);
        LOG(@"kill %@ pid=%d (SIGKILL) - retry activation next cycle", kTargetBundleID, pid);
    } else {
        LOG(@"killApp: wxkb pid not found (procPid)");
    }
}

// 一次预热尝试：没起 -> 前台拉起等 pip.built；起了但挂起超时无 pip.built -> kill 重试。
// v1.9.15：kill 前必须查 suspend_count——只有进程真被挂起（sc>0，锁屏僵尸/视频 PiP 顶掉）
// 才杀；进程活着（sc==0）或拿不到（-1）绝不杀（可能带着 PiP 活着 / pip.built 延迟上报）。
static void warmupOnce(void) {
    if (gPipUp) return;
    if (isAppRunning(kTargetBundleID)) {
        int sc = taskSuspendCount(procPid("wxkb"));
        if (time(NULL) - gWarmupLaunchTs > kKillStaleSec && sc > 0) {
            killApp();
        } else if (sc <= 0) {
            LOG(@"%@ running sc=%d -> alive-ish, no kill (dylib will report pip.built)", kTargetBundleID, sc);
        }
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

// v1.9.2 重预热：死了就拉（老板拍板）。v1.9.8 加 gWarmingUp 防并发
// （回调线程 + 主循环可能同时触发）。v1.9.10：只在解锁态被调用，去掉息屏分支。
// v1.9.15：3 次尝试 -> 2 次，缩短主循环阻塞（否则 watchWechat 被饿死，微信被杀拉不回）
static BOOL gWarmingUp = NO;
static void reWarm(void) {
    if (gWarmingUp) { LOG(@"reWarm: already warming, skip"); return; } // 测试版：详细日志
    gWarmingUp = YES;
    int attempts = 0;
    while (!gPipUp && attempts < 2) {
        @autoreleasepool { warmupOnce(); }
        if (gPipUp) break;
        attempts++;
        sleep(3);
    }
    gWarmingUp = NO;
}

// v1.9.4：无头拉起微信（后台 flag=1，不显 UI 不闪屏），让微信主 App 后台待命。
// 仅 wetype 预热成功后错开几秒执行一次（gWechatWarmed 防重复）。
static BOOL gWechatWarmed = NO;
static time_t gLastWechatPull = 0;   // v1.9.7：微信重拉节流时间戳
static const time_t kWechatRePullInterval = 60; // v1.9.15：120->60，老板要求微信被杀要尽快拉回
static void warmWechatHeadless(void) {
    if (!sbsReady() || !g_SBSLaunch) { LOG(@"wechat headless: SBS unavailable"); return; }
    int r = g_SBSLaunch((__bridge CFStringRef)kWechatBundleID, 1); // SBSApplicationLaunchFlagBackground
    gLastWechatPull = time(NULL);
    LOG(@"wechat headless SBSLaunchApplicationWithIdentifier(%@, Background=1) -> %d (0=ok)",
        kWechatBundleID, r);
}

// v1.9.5：微信无头拉起封装（防重复）。开机路径 + 看护僵尸分支（开机锁屏导致预热稍后
// 才成功）都会调，保证只要 wetype 预热成功过，微信就一定被拉起一次。
// v1.9.15：加节流检查——daemon 重启会重置 gWechatWarmed 导致重复拉，统一用
// gLastWechatPull 节流（与 watchWechat 一致），重复调用直接跳过。
static void maybeWarmWechat(void) {
    if (gWechatWarmed) return;
    gWechatWarmed = YES; // 先置位防重复（sleep 期间若重复进入也只会拉一次）
    if (isWechatRunning()) { LOG(@"wechat already running, skip"); return; }
    if (time(NULL) - gLastWechatPull < kWechatRePullInterval) { LOG(@"wechat pull throttle, skip"); return; }
    LOG(@"sleeping 5s then headless-pull WeChat...");
    sleep(5);
    warmWechatHeadless();
}

// v1.9.7：微信看护——被杀就无头拉（不管息屏，无 UI 无打扰），60s 节流（v1.9.15 缩短）
static void watchWechat(void) {
    if (isWechatRunning()) return;
    time_t now = time(NULL);
    if (now - gLastWechatPull < kWechatRePullInterval) {
        LOG(@"wechat not running but throttle (%.0fs left)",
            (double)(kWechatRePullInterval - (now - gLastWechatPull)));
        return;
    }
    LOG(@"wechat killed -> headless re-pull (screen %s)", gScreenBlank ? "BLANK" : "ON");
    warmWechatHeadless();
}

// ===== v1.9.11 测试：task_for_pid 能否拿其他进程 task port =====
// 用途：判定「纯 daemon 用 Mach Task State 检测 wetype 是否被挂起」方案是否可行。
// 用法：wcvoicekeep --tfp-check <pid>  （真实 daemon 环境 root+platform-application）
#include <mach/mach.h>
#include <mach/task_info.h>
static int tfpCheck(int pid) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    fprintf(stderr, "[TFP-CHECK] task_for_pid(%d) -> %d (%s)\n", pid, kr,
            kr == KERN_SUCCESS ? "OK" : mach_error_string(kr));
    if (kr != KERN_SUCCESS) return 1;
    struct task_basic_info info;
    mach_msg_type_number_t cnt = TASK_BASIC_INFO_COUNT;
    kr = task_info(task, TASK_BASIC_INFO, (task_info_t)&info, &cnt);
    fprintf(stderr, "[TFP-CHECK] task_info -> %d suspend_count=%d resident=%lluKB\n",
            kr, info.suspend_count, (unsigned long long)(info.resident_size / 1024));
    mach_port_deallocate(mach_task_self(), task);
    return 0;
}

// ===== v1.9.13 核心：读 wetype 的 Mach Task suspend_count 判定是否被系统挂起 =====
// 微信视频 PiP 顶掉 wetype PiP -> wetype 无保活凭证 -> 系统挂起进程(S▲B, suspend_count>0)
// -> PiP 失效 -> daemon 重拉。entitlements 需 platform-application + task_for_pid-allow
// （v1.9.12 实测 OK：root daemon -> mobile wetype task_for_pid 0、suspend_count 可读）。
// 挂在 60s 守护 tick 上查一次，微秒级，不增加任何独立轮询/定时器/磁盘写。
static int taskSuspendCount(int pid) {
    if (pid <= 0) return -1;
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;
    struct task_basic_info info;
    mach_msg_type_number_t cnt = TASK_BASIC_INFO_COUNT;
    kr = task_info(task, TASK_BASIC_INFO, (task_info_t)&info, &cnt);
    mach_port_deallocate(mach_task_self(), task);
    if (kr != KERN_SUCCESS) return -1;
    return info.suspend_count;
}

// 其他 App 是否在播音频（视频 PiP/音乐）——有声音时绝不重拉（避免打断看视频）。
// AudioSessionGetProperty 已被 SDK 标记 deprecated，include 头会触发 -Wdeprecated-declarations
// 被 tool 目标的 -Werror 判死，故手写声明绕过（kAudioSessionProperty_OtherAudioIsPlaying='othr'）。
extern int AudioSessionGetProperty(unsigned int inID, unsigned int *ioDataSize, void *outData);
static BOOL otherAudioPlaying(void) {
    unsigned int playing = 0;
    unsigned int sz = sizeof(playing);
    int st = AudioSessionGetProperty('othr', &sz, &playing);
    if (st != 0) { LOG(@"audio check err=%d", st); return NO; }
    return playing != 0;
}

// v1.9.13：PiP 失效重拉冷却（挂起检测到 -> 拉一次失败 -> 5min 内不再试，防反复闪）
static time_t gPiPLostCooldownUntil = 0;
static const time_t kPiPLostCooldownSec = 300;
static void handlePiPLost(int sc) {
    time_t now = time(NULL);
    if (gLocked) { LOG(@"  PiP lost & LOCKED -> wait unlock"); return; }
    if (now < gPiPLostCooldownUntil) { LOG(@"  PiP lost cooldown (%.0fs left) -> skip", (double)(gPiPLostCooldownUntil - now)); return; }
    if (otherAudioPlaying()) { LOG(@"  PiP lost but other audio playing (video/music) -> hold, no flash"); return; }
    gPiPLostCooldownUntil = now + kPiPLostCooldownSec; // 先置冷却，失败也不反复闪
    LOG(@"  PiP lost (suspend_count=%d) & idle & unlocked -> re-warm to rebuild PiP", sc);
    gPipUp = NO;
    reWarm();
    if (gPipUp) maybeWarmWechat();
}

int main(int argc, char *argv[]) {
    // 早期 stderr（不依赖 Foundation/ObjC runtime）——
    // launchd 任何阶段拒收(进程类型/entitlement/签名/sandbox)都能立刻看到，
    // 否则后面 LOG 走 NSLog + 文件句柄,启动被秒拒时来不及写任何东西。
    fprintf(stderr, "[WCVK-DAEMON] main() entered pid=%d uid=%d argv0=%s\n",
            getpid(), getuid(), (argc > 0 && argv[0]) ? argv[0] : "?");
    fflush(stderr);

    // v1.9.11：--tfp-check <pid> 测试分支（真实 daemon 环境），测完即退不影响正常功能
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--tfp-check") == 0 && i + 1 < argc) {
            return tfpCheck(atoi(argv[i + 1]));
        }
    }

    @autoreleasepool {
        LOG(@"==== daemon boot ====");
        LOG(@"pid=%d uid=%d argv0=%s", getpid(), getuid(), argv[0] ?: "?");
        LOG(@"target=%@ trigger=%s pipBuilt=%s", kTargetBundleID, kTriggerName, kPipBuiltName);
        LOG(@"log=%@", kLogPath);

        registerNotifs();
        LOG(@"sleeping %ds for SpringBoard...", kBootDelaySec);
        sleep(kBootDelaySec);

        // 注销后立即预热：最多试 ~2 分钟。
        // v1.9.22：锁屏也拉 wetype（不再跳过）——SB 保活后锁屏拉起不再是僵尸
        //（进程不挂起 + scene active），解锁时 DidBecomeActive 自动建 PiP，无需等
        // lockstate 回调。修"注销后拉起快慢不稳定"（原来拉起时机=用户解锁时机）。
        LOG(@"boot warmup loop until pip.built (max ~2min)...");
        time_t bootStart = time(NULL);
        while (!gPipUp && time(NULL) - bootStart < 120) {
            @autoreleasepool { warmupOnce(); }
            if (gPipUp) break;
            // v1.9.20：微信 3s 点尽早拉；maybeWarmWechat 内部节流防重复
            if (!gWechatWarmed && time(NULL) - bootStart >= 3) maybeWarmWechat();
            sleep(kFastRetrySec);
        }
        LOG(@"boot warmup done (gPipUp=%d) -> entering 60s watch", (int)gPipUp);

        // 兜底：循环结束还没拉过微信就补拉（防 2min 全在锁屏且 30s 点恰好没到）
        maybeWarmWechat();

        // 守护循环（v1.9.10 老板拍板 + v1.9.13 PiP 失效检测）：
        //  - wetype：解锁态死了/僵尸 -> kill+重拉；活着但被系统挂起（suspend_count>0，
        //    微信视频 PiP 顶掉保活凭证）-> PiP 失效 -> 择机重拉（锁屏等解锁/有音频不拉/5min 冷却）
        //  - 微信：被杀就无头拉（不管锁屏/息屏，无 UI 无打扰），120s 节流
        while (1) {
            sleep(kCheckIntervalSec);
            @autoreleasepool {
                watchWechat(); // 微信看护优先（老板要求：微信也要能拉起来）

                if (isAppRunning(kTargetBundleID)) {
                    int pid = procPid("wxkb");
                    int sc = taskSuspendCount(pid); // 权威判定：sc>0=挂起(无PiP)，0=活着，-1=拿不到
                    if (gPipUp) {
                        // v1.9.13：sc>0 = 进程被系统挂起 = PiP 已被顶掉（视频 PiP 抢通道）
                        if (sc > 0) {
                            LOG(@"%@ SUSPENDED (suspend_count=%d pid=%d) -> PiP lost (video PiP took over?)", kTargetBundleID, sc, pid);
                            handlePiPLost(sc); // 锁屏/有音频/冷却期都不拉，只有空闲解锁态才重拉
                        } else {
                            LOG(@"%@ alive -> only trigger dylib", kTargetBundleID); // 测试版：详细日志
                            postTrigger();
                        }
                    } else if (sc > 0) {
                        // v1.9.15：只有真挂起（sc>0）才当僵尸杀；解锁态 kill+重拉
                        if (!gLocked) {
                            LOG(@"%@ zombie & unlocked (sc=%d) -> kill & re-warm", kTargetBundleID, sc);
                            killApp();
                            gPipUp = NO;
                            reWarm();
                            if (gPipUp) maybeWarmWechat();
                        } else {
                            LOG(@"%@ zombie & LOCKED -> skip (lock-screen pull is dead, no PiP)", kTargetBundleID);
                        }
                    } else {
                        // v1.9.15：进程活着（sc==0 可能带 PiP 只是 pip.built 延迟；sc==-1 拿不到）
                        // -> 绝不杀，发 trigger 让 dylib 自己建 PiP/上报
                        LOG(@"%@ running sc=%d, gPipUp=NO -> no kill, trigger dylib (wait pip.built)", kTargetBundleID, sc);
                        postTrigger();
                    }
                    continue;
                }
                if (!gLocked) {
                    LOG(@"%@ NOT running & unlocked -> re-warm", kTargetBundleID);
                    gPipUp = NO;
                    reWarm();
                    if (gPipUp) maybeWarmWechat();
                } else {
                    LOG(@"%@ died & LOCKED -> skip wetype (lock-screen pull is dead, no PiP)", kTargetBundleID);
                }
            }
        }
    }
    return 0;
}
