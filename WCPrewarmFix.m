// WCPrewarmFix.xm —— 注入微信侧「后台预热黑屏」诊断 + 四级修复
//
// 背景（wcvoicekeep v2.0.7 实测证据）：
//   daemon 用 SBSLaunchApplicationWithIdentifier(bid, 1) 在后台把微信**完整启动**，
//   容器里 61 个文件被改写、5 个 sqlite 被打开，scene 以后台非激活态连上后被系统挂起。
//   用户点图标时 SpringBoard 只是「激活已有进程」，不会重跑启动流程 → 黑屏。
//   （v2.0.8 试过 SIGSTOP 造真 prewarm：冻在 0ms，连 dyld 都没跑，进程成 928K 空壳，
//     点开完全不可用。冻结方案已判死，只能从 App 内部修。）
//
// 本 dylib 的职责：
//   1. 判断自己这次是不是「被后台无头拉起的」（关键判据：didFinishLaunching 时
//      applicationState == Background；辅以环境变量 ActivePrewarm）。不是就完全不干预。
//   2. 第一次真正进前台后 1 秒，检查主窗口健康度，把微信内部真实状态全量写日志。
//   3. 不健康就按 L1→L4 逐级修复，每级修完复查，成功即停：
//        L1 抖一下     有 window/rootVC 只是没上屏 → makeKeyAndVisible + 强制 layout + hidden 抖动
//        L2 绑场景     window.windowScene == nil → 绑到前台 active 的 UIWindowScene
//        L3 重挂根     rootVC 存在但不在窗口层级 → 重新赋 rootViewController + 补 appear 回调
//        L4 重放启动   微信压根没建界面（后台启动时它自己跳过了）→ 重发前台通知 + 重放 delegate
//   4. L1~L4 全失败 → 兜底 exit(0)，让下次打开走冷启动（界面一定正常，代价是丢一次热启动）。
//
// 日志：微信沙盒 Documents/wcprewarm.log（沙盒 App 写不了 /var/mobile，从 root 侧读）
//   /var/jb/../private/var/mobile/Containers/Data/Application/<UUID>/Documents/wcprewarm.log
//   实机读取（roothide 要加 rootfs 前缀）：
//   ls -lt /rootfs/private/var/mobile/Containers/Data/Application/*/Documents/wcprewarm.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdlib.h>
#import <limits.h>
#import <string.h>
#import <fcntl.h>
#import <sys/time.h>
#import <sys/stat.h>
#import <errno.h>
#import <notify.h>

// ===== 配置（先写死，实测后再按需做成 plist 开关）=====
#define WCVK_BUILD_TAG "v2.0.26-roothide"
static BOOL const kWPFEnable        = YES;   // 总开关
static BOOL const kWPFExitFallback  = NO;    // 不再 exit(0)：daemon 的 PROC_EXIT 里 kRelaunchDelaySec
                                             // 秒后就会主动再拉，形成「杀-拉-黑」死循环。
// ⛔ v2.0.19 止血开关（老板 02:58 实测「直接进微信根本动不了、切后台都切不了、卡死后闪退重启」）：
//    v2.0.18 的两处原生尝试被我实测判死，全部关掉：
//      ① requestSceneSessionActivation: —— 系统直接回「当前设备不支持多个场景」（微信没有
//         Scene Manifest，是单场景 App），一次都没生效过；
//      ② notify → SpringBoard 侧 SBSLaunchApplicationWithIdentifier —— 该私有 API 在
//         SpringBoard 主线程同步阻塞 **11 秒**（SB 日志：收到请求 18:56:46 → rc=11 18:56:56），
//         期间整个系统卡死、切不了后台；而 rc=11 说明这次启动根本没被受理。
//    所以这两级在 v2.0.19 里彻底删除，微信侧不再发 notify、SpringBoard 侧不再调该 API。
static BOOL const kWPFSafeMode      = YES;   // YES = 只做无害动作（refresh），绝不做任何可能阻塞/搬窗口的事
static double const kWPFCheckDelay  = 0.4;   // v2.0.26: 1.0→0.4，缩短黑屏停留时间（04:38 实测
                                             // 0.4s 时 iConsoleWindow 已建好、scene 已连完）
static double const kWPFRetryDelay  = 1.0;   // 非 Active 态复查间隔
static int    const kWPFRetryMax    = 6;     // 非 Active 态最多复查次数（原来的 3 次太短，
                                             // 日志里 10814 就是复查 2 次进程就换掉了）
static int    const kWPFCheckMax    = 8;     // 同一进程内最多做几次完整检查（节流用）

// ===== 运行状态 =====
static BOOL gWasHeadless   = NO;   // 本次进程是后台无头启动的
static BOOL gEnteredFG     = NO;   // 已经进过前台
static int  gRepairLevel   = 0;    // 实际生效的修复级别（0=没修）
static int  gCheckRetries  = 0;    // 非 Active 态复查次数
static int  gCheckCount    = 0;    // 本进程已做过的检查次数
static double gLastCheckAt = 0;    // 上次检查的绝对时间（节流）
static int  gL1Attempts = 0;       // L1 实际执行次数（防抖动，同一进程最多 2 次）
static int  gL2Attempts = 0;       // L2 实际执行次数
static int  gL3Attempts = 0;       // L3（拆子场景）实际执行次数，每进程最多 1 次

// ===== 日志（v2.0.14）=====
// 老板连续三次反馈「日志还是没有」。照 wctweak 的 WCPLLogger 对比，我旧版差在三个地方：
//   ① wctweak 写在 Library/Application Support/WCPL/，**故意避开 Documents** ——
//      微信的 DiskUsage 磁盘扫描会把 Documents 下的文件搬进 tmp/DiskScanTrash 再整批清掉
//      （wctweak 自己的日志里抓到过这一幕），所以「写进去了又找不到」是常态；
//   ② wctweak 用 NSFileManager **先 createDirectory** 再写，我旧版直接往可能不存在的
//      子目录里 open，失败还静默 return，一点痕迹都不留；
//   ③ wctweak 除了文件还有持久化兜底，我旧版文件写不进去就彻底失明。
//
// 现在四通道全开，任一条走通就能看到内容：
//   A 文件  $HOME/Library/Application Support/WCVK/wcprewarm.log   ← 主通道（微信不扫，最先看这个）
//           + Documents / tmp / Library/Caches / Library/Preferences 兜底
//   B CFPreferences  suite com.wcvoicekeep.prewarmlog ← 走 cfprefsd 服务，沙盒下最稳，
//           落盘在容器 Library/Preferences/com.wcvoicekeep.prewarmlog.plist（plutil 可读）
//   C NSLog
//   D darwin notify 探针（ctor 第一条就 post）→ SpringBoard 侧 wetypekeepalive 收到后写
//     /var/mobile/wetypekeepalive.log。这条**完全不依赖微信沙盒写文件**，
//     用来回答「dylib 到底有没有被执行」这个前置问题。
//
// ctor 里第一条日志会带上 `probe=` 段：HOME 值 + 每个候选的 open 结果/errno，
// 万一哪条都写不进去，这行会先落进 CFPreferences，照样能查到失败原因。
static char gLogPath[PATH_MAX] = {0};   // 空 = 还没找到可写路径
static char gProbeReport[1024] = {0};   // 首次路径探测结论（写进 prefs 备查）

static void WPFMkdirParents(const char *path) {
    char dir[PATH_MAX];
    strlcpy(dir, path, sizeof(dir));
    char *slash = strrchr(dir, '/');
    if (!slash || slash == dir) return;
    *slash = 0;
    for (char *p = dir + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(dir, 0755); *p = '/'; }
    }
    mkdir(dir, 0755);
}

// v2.0.16：探测和写入合并 —— 旧版单独 open(O_CREAT) 探测会在每个候选位置留下 0K 空文件，
// 老板看到「三个地方都有日志但都是 0K」就是这些占位文件造成的误会（真正的内容全在主通道里）。
// 现在只有「open 成功 → 立刻写入当前这行」才算数，失败的候选一个文件都不留。
static char gCand[10][PATH_MAX];
static int  gCandN = 0;

static void WPFPrepareCandidates(void) {
    if (gCandN > 0) return;
    int n = 0;

    // HOME 优先，拿不到再退回 getenv（两条都记下来，方便排查沙盒根异常）
    // ⚠️ homeNS 必须活到函数结束：fileSystemRepresentation 返回的是它内部 buffer 的指针，
    //    在 @try 块内声明会让它提前释放 → 悬垂指针（这类坑比路径写错更难查）。
    __attribute__((objc_precise_lifetime)) NSString *homeNS = nil;
    __attribute__((objc_precise_lifetime)) NSString *tmpNS = nil;
    @try { homeNS = NSHomeDirectory(); } @catch (NSException *e) {}
    const char *home = homeNS.length ? homeNS.fileSystemRepresentation : NULL;
    if (!home || !home[0]) home = getenv("HOME");

    if (home && home[0]) {
        // ① 主通道：Application Support（微信不扫、系统低存储时也不清）
        snprintf(gCand[n++], PATH_MAX, "%s/Library/Application Support/WCVK/wcprewarm.log", home);
        // ② 常用位置
        snprintf(gCand[n++], PATH_MAX, "%s/Documents/wcprewarm.log", home);
        snprintf(gCand[n++], PATH_MAX, "%s/tmp/wcprewarm.log", home);
        snprintf(gCand[n++], PATH_MAX, "%s/Library/Caches/wcprewarm.log", home);
        // ③ 微信自己的日志目录（一定存在）
        snprintf(gCand[n++], PATH_MAX, "%s/Documents/log/wcprewarm.log", home);
    }
    @try { tmpNS = NSTemporaryDirectory(); } @catch (NSException *e) {}
    {
        const char *t = tmpNS.length ? tmpNS.fileSystemRepresentation : NULL;
        if (t && t[0]) snprintf(gCand[n++], PATH_MAX, "%s/wcprewarm.log", t);
    }
    snprintf(gCand[n++], PATH_MAX, "/var/mobile/wcprewarm.log");   // 沙盒外兜底（一般写不进，聊胜于无）

    for (int i = 0; i < n; i++) WPFMkdirParents(gCand[i]);

    snprintf(gProbeReport, sizeof(gProbeReport), "home=%s",
             (home && home[0]) ? home : "(null)");
    gCandN = n;
}

// 通道 B：CFPreferences（cfprefsd 服务，沙盒 app 写自己容器 Preferences 一定成功）
static void WPFStoreAppend(const char *line) {
    static BOOL sOff = NO;
    if (sOff || !line) return;
    @try {
        CFStringRef appID = CFSTR("com.wcvoicekeep.prewarmlog");
        CFStringRef key   = CFSTR("log");
        CFStringRef old   = CFPreferencesCopyAppValue(key, appID);
        NSString *cur = old ? (__bridge_transfer NSString *)old : @"";
        if (cur.length > 20000) cur = [cur substringFromIndex:cur.length - 16000];
        NSString *nv = [cur stringByAppendingString:[NSString stringWithUTF8String:line]];
        if (!nv) return;
        CFPreferencesSetAppValue(key, (__bridge CFStringRef)nv, appID);
        if (!CFPreferencesAppSynchronize(appID)) sOff = YES;
    } @catch (NSException *e) { sOff = YES; }
}

static void WPFAppendRaw(const char *path, const char *buf, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, buf + off, len - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
    close(fd);
}

// 文件通道：首次调用边走边探测边写，成功后把路径与 probe 结论各记一行，之后走快路径。
static void WPFWriteFile(const char *line, size_t len) {
    if (gLogPath[0]) {
        WPFAppendRaw(gLogPath, line, len);
        return;
    }
    WPFPrepareCandidates();
    size_t rl = strlen(gProbeReport);
    for (int i = 0; i < gCandN; i++) {
        int fd = open(gCand[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        int err = errno;
        if (fd >= 0) {
            size_t off = 0;
            while (off < len) {
                ssize_t w = write(fd, line + off, len - off);
                if (w <= 0) break;
                off += (size_t)w;
            }
            close(fd);
            strlcpy(gLogPath, gCand[i], PATH_MAX);
            if (rl < sizeof(gProbeReport) - 400) {
                rl += snprintf(gProbeReport + rl, sizeof(gProbeReport) - rl,
                               " |%s=ok", gCand[i]);
            }
            char rep[2600];
            int n2 = snprintf(rep, sizeof(rep), "log channel: file=%s\nlog probe: %s\n",
                              gLogPath, gProbeReport);
            if (n2 > 0) WPFAppendRaw(gLogPath, rep, (size_t)(n2 < (int)sizeof(rep) ? n2 : (int)sizeof(rep) - 1));
            return;
        }
        if (rl < sizeof(gProbeReport) - 400) {
            const char *tail = strrchr(gCand[i], '/');
            rl += snprintf(gProbeReport + rl, sizeof(gProbeReport) - rl,
                           " |%s=E%d", tail ? tail + 1 : gCand[i], err);
        }
    }
}

static void WPFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!body) return;
    const char *cbody = body.UTF8String;
    if (!cbody) return;

    // 时间用 POSIX，绕开 NSDateFormatter（ctor 早期不可靠）
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    time_t sec = tv.tv_sec;
    localtime_r(&sec, &tmv);
    char ts[32] = {0};
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);

    char line[2048];
    int len = snprintf(line, sizeof(line), "[%s.%03d][%d] %s\n",
                       ts, (int)(tv.tv_usec / 1000), getpid(), cbody);
    if (len <= 0) return;
    if (len >= (int)sizeof(line)) len = (int)sizeof(line) - 1;

    // 通道 C：系统日志
    NSLog(@"[WCPrewarm] %s", cbody);

    // 通道 A：文件
    WPFWriteFile(line, (size_t)len);

    // 通道 B：CFPreferences（文件全失败也有一条命）
    WPFStoreAppend(line);
}

// ===== 工具 =====
static NSString *WPFClassChain(id obj) {
    if (!obj) return @"(nil)";
    NSMutableString *s = [NSMutableString string];
    Class c = object_getClass(obj);
    int n = 0;
    while (c && n++ < 6) {
        [s appendFormat:@"%@%@", n > 1 ? @" < " : @"", NSStringFromClass(c)];
        c = class_getSuperclass(c);
    }
    return s;
}

static UIWindowScene *WPFActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback && s.activationState == UISceneActivationStateForegroundInactive) fallback = (UIWindowScene *)s;
    }
    return fallback;
}

// 找微信的主窗口：优先 delegate.window，其次 keyWindow，最后扫全量窗口挑最像主界面的
static UIWindow *WPFMainWindow(UIApplication *app) {
    id d = app.delegate;
    if ([d respondsToSelector:@selector(window)]) {
        UIWindow *w = nil;
        @try { w = [d window]; } @catch (NSException *e) {}
        if ([w isKindOfClass:[UIWindow class]]) return w;
    }
    UIWindow *kw = nil;
    @try { kw = app.keyWindow; } @catch (NSException *e) {}
    if ([kw isKindOfClass:[UIWindow class]]) return kw;

    UIWindow *best = nil;
    CGFloat bestArea = 0;
    for (UIWindow *w in app.windows) {
        if (w.windowLevel != UIWindowLevelNormal) continue;
        NSString *rc = w.rootViewController ? NSStringFromClass([w.rootViewController class]) : @"";
        BOOL looksMain = [rc rangeOfString:@"MainFrame" options:NSCaseInsensitiveSearch].location != NSNotFound
                      || [rc rangeOfString:@"TabBar" options:NSCaseInsensitiveSearch].location != NSNotFound;
        CGFloat area = w.bounds.size.width * w.bounds.size.height;
        if (looksMain) return w;
        if (area > bestArea) { bestArea = area; best = w; }
    }
    return best;
}

// 主窗口是否"真的在屏幕上、有内容"
static BOOL WPFWindowAlive(UIWindow *w) {
    if (!w) return NO;
    if (w.isHidden) return NO;
    if (w.alpha < 0.01) return NO;
    if (w.bounds.size.width < 1 || w.bounds.size.height < 1) return NO;
    UIViewController *vc = w.rootViewController;
    if (!vc) return NO;
    if (!vc.view) return NO;
    if (vc.view.window != w) return NO;                       // 视图没挂在窗口上 → 不会显示
    if (vc.view.bounds.size.width < 1 || vc.view.bounds.size.height < 1) return NO;
    return YES;
}

// ⭐ v2.0.16：结构健康 ≠ 用户能看到画面。
// v2.0.15 实机日志里 iConsoleWindow 满足全部结构条件（rootVC=MainTabBarViewController、
// viewInWin=1、hidden=0、alpha=1），alive 判成 1 → 直接 return 不修，可用户看到的就是黑屏。
// 所以判定必须换成「真的有没有像素」，再补一条「窗口绑的 scene 是不是在台上」。
static BOOL WPFSceneOnStage(UIWindow *w) {
    if (!w) return NO;
    UIWindowScene *ws = w.windowScene;
    if (!ws) return NO;                                        // 没有 scene → 不可能显示
    UISceneActivationState st = ws.activationState;
    if (st == UISceneActivationStateForegroundActive) return YES;
    if (st == UISceneActivationStateForegroundInactive) return YES;
    return NO;                                                 // background / unattached → 必然黑
}

// 离屏快照判黑：把窗口渲染到 16x16，统计"非黑"像素比例。
// 返回 YES = 判定为黑屏。比例本身也会写进日志，方便人复核（微信深色界面可能天然偏暗，
// 所以阈值取 3%，且只在 headless 首次进前台时跑一次，不影响日常）。
static BOOL WPFSnapshotBlank(UIWindow *w) {
    if (!w || w.bounds.size.width < 1 || w.bounds.size.height < 1) return YES;
    CGFloat ratio = 0;
    BOOL rendered = NO;
    @try {
        const size_t dim = 16;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(dim, dim), YES, 1.0);
        rendered = [w drawViewHierarchyInRect:CGRectMake(0, 0, dim, dim) afterScreenUpdates:NO];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (rendered && img.CGImage) {
            CGImageRef cg = img.CGImage;
            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(cg));
            if (data) {
                const UInt8 *px = CFDataGetBytePtr(data);
                size_t n = (size_t)CFDataGetLength(data);
                size_t nonzero = 0, total = n / 4;
                for (size_t i = 0; i + 3 < n; i += 4) {
                    if (px[i] > 12 || px[i + 1] > 12 || px[i + 2] > 12) nonzero++;
                }
                ratio = total ? (CGFloat)nonzero / (CGFloat)total : 0;
                CFRelease(data);
            }
        }
    } @catch (NSException *e) {
        WPFLog(@"snapshot 异常: %@", e.reason);
        return YES;
    }
    BOOL blank = (!rendered) || (ratio < 0.03);
    WPFLog(@"snapshot: rendered=%d 非黑像素=%.1f%% → %@", rendered ? 1 : 0, ratio * 100.0,
           blank ? @"判定黑屏" : @"有画面");
    return blank;
}

// ⭐ v2.0.17 核心修正：统一的「健康」判据。
// v2.0.16 的致命 bug：判定黑屏用「alive && sceneOnStage」，修完复查却只查 alive。
// 于是 L1 做完（makeKeyAndVisible 对挂错 scene 的窗口完全无效）复查 alive 依旧 =1，
// 立刻打印「*** 修复成功，生效级别 L1 ***」并终止链条 —— 真正能治病的 L2 永远跑不到。
// v2.0.16 实机日志（pid 10819 / 10823）两次都是这个剧本：修完 sceneOnStage 还是 0。
static BOOL WPFHealthy(UIWindow *w, BOOL wantSnapshot) {
    if (!WPFWindowAlive(w)) return NO;
    if (!WPFSceneOnStage(w)) return NO;
    // 快照只在 Active 态有意义；Inactive/Background 下离屏渲染本来就是空的
    if (wantSnapshot && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        if (WPFSnapshotBlank(w)) return NO;
    }
    return YES;
}

// 全量状态 dump（诊断核心：黑屏那一刻微信内部到底是什么样）
static void WPFDumpState(NSString *tag) {
    UIApplication *app = [UIApplication sharedApplication];
    WPFLog(@"---- STATE %@ ----", tag);
    WPFLog(@"appState=%ld delegate=%@ headless=%d enteredFG=%d",
           (long)app.applicationState, WPFClassChain(app.delegate), gWasHeadless, gEnteredFG);

    NSMutableString *sc = [NSMutableString string];
    for (UIScene *s in app.connectedScenes) {
        [sc appendFormat:@"%p(state=%ld) ", (__bridge void *)s, (long)s.activationState];
    }
    WPFLog(@"scenes(%lu): %@", (unsigned long)app.connectedScenes.count, sc.length ? sc : @"(none)");

    // v2.0.19：单个 scene 的细节 —— 下一步不管走哪条路，都要先知道
    // 「两个 scene 各自的 session / 角色 / 上面有几个能显示的窗口」。
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) {
            WPFLog(@"  scene %p class=%@ state=%ld（非 UIWindowScene）",
                   (__bridge void *)s, NSStringFromClass([s class]), (long)s.activationState);
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)s;
        UISceneSession *ss = ws.session;
        unsigned long showable = 0, total = ws.windows.count;
        NSMutableString *wn = [NSMutableString string];
        for (UIWindow *x in ws.windows) {
            if (!x.isHidden && x.rootViewController) showable++;
            [wn appendFormat:@"%@%@,", NSStringFromClass([x class]), x.isHidden ? @"(hidden)" : @""];
        }
        WPFLog(@"  scene %p state=%ld session=%@ role=%@ delegate=%@ windows=%lu 可用=%lu [%@]",
               (__bridge void *)ws, (long)ws.activationState,
               ss.persistentIdentifier ?: @"(nil)",
               ss.role ?: @"(nil)",
               WPFClassChain(ws.delegate), total, showable,
               wn.length ? wn : @"(空)");
    }

    NSArray<UIWindow *> *wins = app.windows;
    WPFLog(@"windows(%lu):", (unsigned long)wins.count);
    for (UIWindow *w in wins) {
        UIViewController *vc = w.rootViewController;
        NSString *vcs = vc ? NSStringFromClass([vc class]) : @"(nil)";
        UIWindowScene *ws = w.windowScene;
        WPFLog(@"  win %@ hidden=%d alpha=%.2f level=%.1f frame=%.0fx%.0f key=%d scene=%p/sceneState=%ld rootVC=%@ viewInWin=%d subviews=%lu",
               NSStringFromClass([w class]), (int)w.isHidden, w.alpha, w.windowLevel,
               w.bounds.size.width, w.bounds.size.height, w.isKeyWindow ? 1 : 0,
               (__bridge void *)ws, ws ? (long)ws.activationState : (long)-1,
               vcs, (vc && vc.view.window == w) ? 1 : 0,
               (unsigned long)(vc ? vc.view.subviews.count : 0));
    }
    UIWindow *main = WPFMainWindow(app);
    WPFLog(@"mainWindow=%@ alive=%d sceneOnStage=%d", main ? NSStringFromClass([main class]) : @"(nil)",
           WPFWindowAlive(main) ? 1 : 0, WPFSceneOnStage(main) ? 1 : 0);
    WPFLog(@"---- END %@ ----", tag);
}

// ===== L1/L2 原生修复（v2.0.18 起只保留这两级，非原生的 L3/L4 已删除）=====
// 返回 YES = 这一级做过了（是否真修好由调用方复查）
static BOOL WPFRepairLevel1(UIWindow *w) {
    if (!w) return NO;
    if (gL1Attempts >= 2) { WPFLog(@"L1: 已执行 %d 次，本次跳过（防抖动）", gL1Attempts); return NO; }
    // v2.0.17：窗口没挂在台上的话，makeKeyAndVisible 不但没用，还会把 keyWindow 抢掉
    // （v2.0.16 日志里 key 从 1 变 0 就是这个），直接交给 L2 处理。
    if (!WPFSceneOnStage(w)) {
        WPFLog(@"L1: 跳过（窗口 scene 不在台上，makeKeyAndVisible 无意义）→ 交给 L2");
        return NO;
    }
    gL1Attempts++;
    WPFLog(@"L1(%d): makeKeyAndVisible + 强制 layout + hidden 抖动", gL1Attempts);
    @try {
        [w makeKeyAndVisible];
        w.hidden = YES;
        w.hidden = NO;
        [w setNeedsLayout];
        [w layoutIfNeeded];
        UIViewController *vc = w.rootViewController;
        [vc.view setNeedsLayout];
        [vc.view layoutIfNeeded];
        [vc.view setNeedsDisplay];
    } @catch (NSException *e) { WPFLog(@"L1 异常: %@", e.reason); return NO; }
    return YES;
}

// ⭐ v2.0.19 L2：**只保留真正无害的那一步**。
// v2.0.18 的两级实测判死（老板 02:58 实测：直接进微信动不了、切后台都切不了、卡死很久才闪退重启）：
//   ① requestSceneSessionActivation: → 系统回「当前设备不支持多个场景」
//      （微信没有 UIApplicationSceneManifest，是单场景 App），errorHandler 同步就返回，从未生效；
//   ③ notify → SpringBoard → SBSLaunchApplicationWithIdentifier(bid, false)
//      → SB 日志铁证：收到请求 18:56:46，rc=11 在 18:56:56 —— **主线程同步阻塞整 11 秒**，
//        期间 SpringBoard 完全无响应（这就是「切后台都切不了」），而且 rc=11 表示启动没被受理。
//        微信侧同一时刻的「L2 之后复查」也被从 1.5s 拖到 10s（02:57:43.364 → 02:57:53.675），
//        说明两边互锁：SB 等微信响应，微信主线程在等 SB。
// 所以 ①③ 整段删除，只留 ②（requestSceneSessionRefresh：纯异步、无返回值、不改任何状态）。
// ===== v2.0.20 L3：请系统拆掉「冒充前台的子场景」 =====
// v2.0.19 实机日志（31 个 dump 块精确统计）第一次把黑屏的形态定死了：
//   正常 18 次：scenes=1，delegate=MMMainSceneDelegate，state=0，窗口 iConsoleWindow，可用=1
//   黑屏  8 次：scenes=2
//      前台 state=0/1 → delegate=MMSubSceneDelegate，可用窗口=0，只有 MMSubSceneWindow(hidden)
//      后台 state=2   → delegate=MMMainSceneDelegate，可用窗口=1，iConsoleWindow 就挂在它上面
// ⇒ **主窗口从来没有挂错 scene**！错的是「系统把 sub scene 激活成了前台」。
//   （v2.0.17 用 setWindowScene 把主窗口从 main scene 搬到 sub scene，等于把主界面塞进
//     微信的子场景里，所以界面亮了但微信内部状态全乱、通讯录读不出来。那条路彻底作废。）
// 处理：请系统销毁那个「没有任何可用窗口、却占着前台态」的子 session。
//       剩下的 main session 只有它一个，系统必须重新激活它 → 界面回来。
//       全程不碰任何 window / windowScene 属性，只发一个标准的 UIApplication 请求。
static NSUInteger WPFUsableWindowCount(UIWindowScene *ws) {
    NSUInteger n = 0;
    for (UIWindow *w in ws.windows) {
        if (w.isHidden || !w.rootViewController) continue;
        if (w.rootViewController.view.window != w) continue;
        if (w.bounds.size.width < 1 || w.bounds.size.height < 1) continue;
        n++;
    }
    return n;
}

// 返回「占着前台态却没有任何可用窗口」的 scene；outMainScene = 另一个有可用窗口的 scene
static UIWindowScene *WPFEmptyForegroundScene(UIWindowScene **outMainScene) {
    UIWindowScene *mainScene = nil, *emptyFg = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        NSUInteger usable = WPFUsableWindowCount(ws);
        if (usable > 0) {
            // 有可用窗口的就是"真正有界面的那个"
            if (!mainScene || ws.activationState == UISceneActivationStateForegroundActive) mainScene = ws;
        } else {
            UISceneActivationState st = ws.activationState;
            if ((st == UISceneActivationStateForegroundActive ||
                 st == UISceneActivationStateForegroundInactive) && !emptyFg) {
                emptyFg = ws;
            }
        }
    }
    if (outMainScene) *outMainScene = mainScene;
    return emptyFg;
}

// v2.0.25：L3 已从修复链摘除（scene API 在单场景 App 上被同步拒绝），保留实现仅供日志排查。
__attribute__((unused)) static BOOL WPFRepairLevel3(UIWindow *w) {
    if (gL3Attempts >= 1) { WPFLog(@"L3: 本进程已试过，跳过"); return NO; }
    UIWindowScene *mainScene = nil;
    UIWindowScene *bad = WPFEmptyForegroundScene(&mainScene);
    if (!bad || !bad.session) {
        WPFLog(@"L3: 跳过（没有「占前台但无可用窗口」的 scene）");
        return NO;
    }
    if (!mainScene) {
        WPFLog(@"L3: 跳过（找不到有可用窗口的主 scene，不能乱拆）");
        return NO;
    }
    if (mainScene == bad) { WPFLog(@"L3: 跳过（同一 scene）"); return NO; }
    gL3Attempts++;

    NSUInteger badN = WPFUsableWindowCount(bad), mainN = WPFUsableWindowCount(mainScene);
    WPFLog(@"L3(%d): 拆子场景 —— 待销毁 scene=%p state=%ld session=%@ 可用=%lu 窗口=[%@]",
           gL3Attempts, (__bridge void *)bad, (long)bad.activationState,
           bad.session.persistentIdentifier ?: @"(nil)", (unsigned long)badN,
           bad.windows.count ? NSStringFromClass([bad.windows.firstObject class]) : @"(空)");
    WPFLog(@"L3(%d): 保留主场景 scene=%p state=%ld session=%@ 可用=%lu 窗口=[%@]",
           gL3Attempts, (__bridge void *)mainScene, (long)mainScene.activationState,
           mainScene.session.persistentIdentifier ?: @"(nil)", (unsigned long)mainN,
           mainScene.windows.count ? NSStringFromClass([mainScene.windows.firstObject class]) : @"(空)");

    // ⭐ v2.0.21：顺序反过来 —— 先「请系统把 main session 请上台」，
    //   这才是「让系统别再激活 sub、改激活 main」的原生做法（v2.0.20 先销毁，而销毁在
    //   单场景 App 上被同一道门槛挡掉，所以什么都没发生）。
    //   销毁退到最后：只有当 main 请不上台时才拆 sub。
    UIApplication *app = [UIApplication sharedApplication];
    UISceneSession *ms = mainScene.session;
    WPFLog(@"L3(%d)①: 请系统激活 main session %@（= 让系统不再把 sub 当前台）",
           gL3Attempts, ms.persistentIdentifier ?: @"(nil)");
    @try {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [app requestSceneSessionActivation:ms userActivity:nil options:nil errorHandler:^(NSError *e) {
            WPFLog(@"L3① 被系统拒绝: %@ (%@)", e.localizedDescription, e.domain);
        }];
        #pragma clang diagnostic pop
    } @catch (NSException *e) { WPFLog(@"L3① 异常: %@", e.reason); }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *a = [UIApplication sharedApplication];
        UIWindow *mw = WPFMainWindow(a);
        if (WPFHealthy(mw, YES)) { WPFLog(@"L3① 成功：main session 上台，界面已恢复（sceneOnStage=1）"); return; }

        // ② main 请不上台 → 退一步请系统销毁那个空子场景，逼系统重新激活唯一剩下的 main
        UISceneSession *bs = bad.session;
        if (!bs) { WPFLog(@"L3: 子场景 session 已不存在，结束"); return; }
        WPFLog(@"L3(%d)②: main 仍未上台，改为请系统销毁 sub session %@",
               gL3Attempts, bs.persistentIdentifier ?: @"(nil)");
        @try {
            [a requestSceneSessionDestruction:bs options:nil errorHandler:^(NSError *e) {
                WPFLog(@"L3② requestSceneSessionDestruction 被拒绝: %@ (%@)", e.localizedDescription, e.domain);
            }];
        } @catch (NSException *e) { WPFLog(@"L3② 异常: %@", e.reason); }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *a2 = [UIApplication sharedApplication];
            if (WPFHealthy(WPFMainWindow(a2), YES)) { WPFLog(@"L3② 成功：拆掉 sub 后界面恢复"); return; }
            WPFLog(@"L3: ①② 都没让 main 上台（scene API 仍未生效或系统不理），放弃本进程");
            WPFDumpState(@"L3 放弃");
        });
    });

    return YES;
}

// ============================================================
// ★★ v2.0.25 L2 全重写：走「窗口」那一套（老板 2026-11-07 定调）
// ------------------------------------------------------------
// 老板的判断：「肯定是一个黑屏的窗口盖在微信主窗口上面了，从窗口这个思路解决」。
// 前面 v2.0.19~v2.0.24 全在 scene API / 会话文件上打，始终没碰窗口层级本身，
// 这就是为什么"改了这么多版还是黑"。
//
// 实机证据（04:15:56~04:16:07）：
//   scenes(2)
//     前台 state=0：windows=0，可用=0  → 一个空 scene 霸着前台，系统给它铺的就是纯黑底
//     后台 state=2：windows=1，可用=1  → iConsoleWindow + MainTabBarViewController 全在这里
//   windows(1)：只有 iConsoleWindow 一个，hidden=0 alpha=1 rootVC 正常
// ⇒ 主窗口本身没问题，问题是它**挂在一个后台 scene 上**，系统不渲染后台 scene 的窗口，
//   于是前台空 scene 的黑底就成了用户看到的画面。所以必须做两件事：
//     a) 把所有"可能盖在上面"的窗口（子场景窗口/无 rootVC 的全屏空窗）压到底/隐藏
//     b) 把主窗口搬到前台 scene 上并重新布局 —— 纯窗口层操作，不碰 scene API
//   b 唯一风险是搬完 VC 不再收到出现回调（v2.0.17 通讯录空就是这个），
//   所以搬家后补一次**官方** beginAppearanceTransition/endAppearanceTransition（容器转场专用公开 API，
//   不是伪造通知，不是手调 viewWillAppear）。
// ============================================================
static UIWindowScene *gWPFSavedMainScene = nil;    // 搬家前主窗口的 scene，用于回滚
static int gWPFSuppressedCount = 0;

// L2-a：压制所有"不是主窗口、却可能盖在上面"的窗口
static int WPFOppressOtherWindows(UIWindow *main) {
    int n = 0;
    NSArray<UIWindow *> *all = [UIApplication sharedApplication].windows;
    for (UIWindow *x in all) {
        if (x == main || !x) continue;
        NSString *cls = NSStringFromClass([x class]);
        BOOL nameSub = ([cls rangeOfString:@"SubScene" options:NSCaseInsensitiveSearch].location != NSNotFound);
        BOOL noRoot  = (x.rootViewController == nil);
        BOOL fullscreen = (main.bounds.size.height > 1) &&
                          (x.bounds.size.height >= main.bounds.size.height * 0.9) &&
                          (x.bounds.size.width  >= main.bounds.size.width  * 0.9);
        // 只压这三类：子场景窗、没有 rootVC 的空窗、和主窗同尺寸却层级更高的窗
        BOOL overlay = nameSub || noRoot || (fullscreen && x.windowLevel >= main.windowLevel && !x.isHidden);
        if (!overlay) continue;
        WPFLog(@"L2a: 压制可疑覆盖窗 %@ hidden=%d alpha=%.2f level=%.1f %.0fx%.0f rootVC=%@",
               cls, (int)x.isHidden, x.alpha, x.windowLevel,
               x.bounds.size.width, x.bounds.size.height,
               x.rootViewController ? NSStringFromClass([x.rootViewController class]) : @"(nil)");
        @try {
            x.hidden = YES;
            x.alpha = 0.0;
            x.windowLevel = -1000.0;     // 压到所有窗口之下
        } @catch (NSException *e) { WPFLog(@"L2a 异常: %@", e.reason); }
        n++;
    }
    gWPFSuppressedCount = n;
    WPFLog(@"L2a: 共压制 %d 个窗口（主窗口=%@ level=%.1f）",
           n, NSStringFromClass([main class]), main.windowLevel);
    return n;
}

// L2-b：主窗口提到最前 + 强制布局（不搬 scene）
static void WPFRaiseMainWindow(UIWindow *main) {
    @try {
        main.hidden = NO;
        main.alpha = 1.0;
        if (main.windowLevel < UIWindowLevelNormal) main.windowLevel = UIWindowLevelNormal;
        [main makeKeyAndVisible];
        [main setNeedsLayout];
        [main layoutIfNeeded];
        UIViewController *vc = main.rootViewController;
        if (vc.view) {
            if (vc.view.frame.size.width < 1 || vc.view.frame.size.height < 1)
                vc.view.frame = main.bounds;
            [vc.view setNeedsLayout];
            [vc.view layoutIfNeeded];
            [vc.view setNeedsDisplay];
        }
        WPFLog(@"L2b: 主窗口已提到最前（level=%.1f key=%d hidden=%d alpha=%.2f）",
               main.windowLevel, main.isKeyWindow ? 1 : 0, (int)main.isHidden, main.alpha);
    } @catch (NSException *e) { WPFLog(@"L2b 异常: %@", e.reason); }
}

// L2-c：把主窗口搬到前台 scene（窗口层唯一能让它重新被渲染的办法）
static BOOL WPFMoveMainWindowToFrontScene(UIWindow *main) {
    if (!main) return NO;
    UIWindowScene *front = WPFActiveScene();
    UIWindowScene *owned = main.windowScene;
    if (!front) { WPFLog(@"L2c: 跳过（没有前台 scene）"); return NO; }
    if (front == owned) { WPFLog(@"L2c: 跳过（主窗口已经在前台 scene 上）"); return NO; }
    WPFLog(@"L2c: 搬家 —— 主窗口 %p 从 scene %p(state=%ld) 搬到前台 scene %p(state=%ld)",
           (__bridge void *)main,
           (__bridge void *)owned, owned ? (long)owned.activationState : (long)-1,
           (__bridge void *)front, (long)front.activationState);
    gWPFSavedMainScene = owned;
    @try {
        main.windowScene = front;
    } @catch (NSException *e) {
        WPFLog(@"L2c 搬家异常: %@", e.reason);
        gWPFSavedMainScene = nil;
        return NO;
    }
    @try {
        UIViewController *vc = main.rootViewController;
        BOOL appeared = NO;
        if (vc) {
            // 官方容器转场 API：只让 VC 重走一遍出现流程，不伪造通知、不手调 viewWillAppear
            [vc beginAppearanceTransition:YES animated:NO];
            appeared = YES;
        }
        main.hidden = NO;
        main.alpha = 1.0;
        [main makeKeyAndVisible];
        [main setNeedsLayout];
        [main layoutIfNeeded];
        if (vc.view) {
            vc.view.frame = main.bounds;
            [vc.view setNeedsLayout];
            [vc.view layoutIfNeeded];
            [vc.view setNeedsDisplay];
        }
        if (appeared) [vc endAppearanceTransition];
        WPFLog(@"L2c: 搬家完成，主窗口 scene=%p(state=%ld) 可用窗口=%lu",
               (__bridge void *)main.windowScene,
               main.windowScene ? (long)main.windowScene.activationState : (long)-1,
               (unsigned long)WPFUsableWindowCount(main.windowScene));
    } @catch (NSException *e) { WPFLog(@"L2c 布局异常: %@", e.reason); }
    return YES;
}

// L2-d：搬家后仍黑 -> 回滚到原 scene，避免把微信内部状态搞乱
static void WPFRollbackMainScene(UIWindow *main) {
    if (!main || !gWPFSavedMainScene) return;
    WPFLog(@"L2d: 搬家后仍黑，回滚主窗口到原 scene %p", (__bridge void *)gWPFSavedMainScene);
    @try {
        main.windowScene = gWPFSavedMainScene;
        [main setNeedsLayout];
        [main layoutIfNeeded];
    } @catch (NSException *e) { WPFLog(@"L2d 回滚异常: %@", e.reason); }
    gWPFSavedMainScene = nil;
}

static BOOL WPFRepairLevel2(UIWindow *w) {
    if (!w) { WPFLog(@"L2: 跳过（没有主窗口）"); return NO; }
    if (gL2Attempts >= 6) { WPFLog(@"L2: 本进程已试过 %d 次，不再重复（防抖动）", gL2Attempts); return NO; }
    gL2Attempts++;

    UIWindowScene *owned = w.windowScene;
    UIWindowScene *front = WPFActiveScene();
    NSUInteger frontUsable = front ? WPFUsableWindowCount(front) : 0;
    WPFLog(@"L2(%d): 主窗口 scene=%p(state=%ld) 前台 scene=%p(state=%ld) 前台可用窗口=%lu 全部窗口=%lu",
           gL2Attempts,
           (__bridge void *)owned, owned ? (long)owned.activationState : (long)-1,
           (__bridge void *)front, front ? (long)front.activationState : (long)-1,
           (unsigned long)frontUsable,
           (unsigned long)[UIApplication sharedApplication].windows.count);

    // ⭐⭐ v2.0.26 快速路径（依据 04:38:19 实机日志定论）：
    //   生效的动作只有 L2c 搬家；L2a 压制 0 个窗口、L2b 提层后 sceneOnStage 仍然是 0 —— 都没用。
    //   而「主窗口在别的 scene + 前台 scene 一个可用窗口都没有」这个组合一旦成立，
    //   a/b 必然无效（提层改变不了"窗口挂在后台 scene 就不渲染"这件事）。
    //   ⇒ 命中就直接搬家，不再白等 0.7s，把黑屏时间从 ~2.5s 压到 ~0.3s。
    BOOL mustMove = (front != nil) && (front != owned) && (frontUsable == 0);
    if (mustMove) {
        WPFLog(@"L2: 快速路径 —— 主窗口挂在 scene %p(state=%ld)，前台 scene %p(state=%ld) 可用窗口=0，直接搬家",
               (__bridge void *)owned, owned ? (long)owned.activationState : (long)-1,
               (__bridge void *)front, (long)front.activationState);
        WPFOppressOtherWindows(w);           // 顺手压掉可能存在的覆盖窗（成本极低）
        if (WPFMoveMainWindowToFrontScene(w)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIApplication *a = [UIApplication sharedApplication];
                UIWindow *mw = WPFMainWindow(a);
                if (WPFHealthy(mw, YES)) {
                    WPFLog(@"L2c(快速) 成功：搬完 %.2fs 内界面恢复", 0.35);
                    return;
                }
                WPFRollbackMainScene(mw);
                WPFLog(@"L2c(快速) 搬家后仍未恢复，已回滚");
                WPFDumpState(@"L2 快速路径失败");
            });
            return YES;
        }
        WPFLog(@"L2: 快速路径搬家失败，回落到通用流程");
    }

    // a) 先把可疑覆盖窗压掉
    WPFOppressOtherWindows(w);
    // b) 再把主窗口提层并重排
    WPFRaiseMainWindow(w);

    // 0.7s 后复查：还黑就搬家（窗口层真正的杀招）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *mw = WPFMainWindow(app);
        if (WPFHealthy(mw, YES)) { WPFLog(@"L2(ab) 成功：压制/提层后界面恢复"); return; }

        BOOL moved = WPFMoveMainWindowToFrontScene(mw);
        if (!moved) {
            WPFLog(@"L2c: 没能搬家（可能主窗口已在前台 scene，或没有前台 scene）");
            WPFDumpState(@"L2c 未搬家");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *a2 = [UIApplication sharedApplication];
            UIWindow *mw2 = WPFMainWindow(a2);
            if (WPFHealthy(mw2, YES)) {
                WPFLog(@"L2c 成功：主窗口搬到前台 scene 后界面恢复（黑屏解决）");
                return;
            }
            WPFRollbackMainScene(mw2);
            WPFLog(@"L2: abc 全部未让界面恢复");
            WPFDumpState(@"L2 放弃");
        });
    });
    return YES;
}



// v2.0.18：L3（重挂 rootVC + 手补 viewWillAppear/viewDidAppear）和
// L4（伪造 UIApplicationWillEnterForeground/DidBecomeActive 通知 + 手调 delegate）
// 整套删除。它们和 setWindowScene 一样属于「自己动手造一个看起来正常的界面」，
// 老板定调只走原生。真要重建界面，就靠 L2 让系统/微信自己走一遍原生激活流程。
// ⛔ 不要再加回来。

// 逐级修复：每级做完等一会儿复查，修好立即停
static void WPFRepairChain_(int level);

// 当前应该修/检查的目标窗口（v2.0.18：不再自造窗口，永远就是微信自己的主窗口）
static UIWindow *WPFTargetWindow(UIApplication *app) {
    return WPFMainWindow(app);
}

static void WPFCheckAfterRepair(UIApplication *app, int nextLevel, int doneLevel) {
    // L3 是「销毁子 session + 兜底激活」，要等销毁真正落地；L2 是系统刷新；L1 是进程内的
    double wait = (doneLevel >= 3) ? 2.5 : ((doneLevel >= 2) ? 1.5 : 0.6);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = WPFTargetWindow(app);
        BOOL alive = WPFWindowAlive(w);
        BOOL staged = WPFSceneOnStage(w);
        BOOL ok = WPFHealthy(w, YES);       // ★ 判据必须和「判定黑屏」时一致，否则永远假成功
        WPFLog(@"复查(L%d 之后): alive=%d sceneOnStage=%d healthy=%d",
               doneLevel, alive ? 1 : 0, staged ? 1 : 0, ok ? 1 : 0);
        if (ok) {
            gRepairLevel = doneLevel;
            WPFLog(@"*** 修复成功，生效级别 L%d ***", doneLevel);
            WPFDumpState(@"修复后");
            return;
        }
        if (nextLevel > 3) {
            WPFLog(@"*** 原生修复（L1/L2/L3）无效 ***");
            WPFDumpState(@"修复失败");
            WPFLog(@"保持现状，等用户下次前台激活再试（不 exit、不硬改 UI）");
            return;
        }
        WPFRepairChain_(nextLevel);
    });
}

static void WPFRepairChain_(int level) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *w = WPFTargetWindow(app);
    BOOL did = NO;
    switch (level) {
        case 1: did = WPFRepairLevel1(w); break;
        case 2: did = WPFRepairLevel2(w); break;
        // ★ v2.0.25：L3（requestSceneSessionActivation / Destruction）已实机证死 ——
        //   单场景 App 上两个 API 都同步返回「当前设备不支持多个场景」，一次都没生效。
        //   所以第 3 轮改成「窗口层再来一遍」（搬家 + 提层，允许复发时重试），不再碰 scene API。
        case 3: did = WPFRepairLevel2(w); break;
        default: did = NO; break;
    }
    if (!did) WPFLog(@"L%d 未执行（条件不满足）", level);
    WPFCheckAfterRepair(app, level + 1, level);
}

static void WPFDoCheck(NSString *reason) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *w = WPFTargetWindow(app);
    BOOL alive  = WPFWindowAlive(w);
    BOOL staged = WPFSceneOnStage(w);

    // ★★ v2.0.25 关键修正：结构判定**不再等 appState == Active**。
    //   04:31 日志显示 headless 拉起后 1.0s 就从 Active 掉到 Inactive（appState=1），
    //   旧代码一路「非 Active，1.0s 后复查」，复查 6 次时微信早就 didEnterBackground 了，
    //   于是整个修复链从来没跑过。而黑屏形态（前台 scene 没有任何可用窗口）在 Inactive 下
    //   判断得一清二楚 —— 根本不需要真前台。
    UIWindowScene *front = WPFActiveScene();
    NSUInteger frontUsable = front ? WPFUsableWindowCount(front) : 0;
    NSArray<UIWindow *> *allWins = app.windows;
    WPFLog(@"检查(%@): mainWindow=%@ alive=%d sceneOnStage=%d appState=%ld "
           @"前台scene=%p(state=%ld) 前台可用窗口=%lu 全部窗口=%lu 已检查%d次/生效L%d",
           reason, w ? NSStringFromClass([w class]) : @"(nil)", alive ? 1 : 0, staged ? 1 : 0,
           (long)app.applicationState,
           (__bridge void *)front, front ? (long)front.activationState : (long)-1,
           (unsigned long)frontUsable, (unsigned long)allWins.count,
           gCheckCount, gRepairLevel);

    BOOL structBlank = (!alive) || (!staged) || (frontUsable == 0);
    if (structBlank) {
        WPFLog(@"判定黑屏（结构: alive=%d staged=%d 前台可用窗口=%lu）-> 窗口层修复",
               alive ? 1 : 0, staged ? 1 : 0, (unsigned long)frontUsable);
        WPFDumpState(reason);
        WPFRepairChain_(2);          // v2.0.25：黑屏只走窗口层（L2），scene API 那条路已证死
        return;
    }

    // 结构正常，最后用像素定死（只在真前台做离屏渲染，其它时候渲染本来就是空的）
    if (app.applicationState == UIApplicationStateActive && WPFSnapshotBlank(w)) {
        WPFLog(@"判定黑屏（结构正常但快照无画面）-> 窗口层修复");
        WPFDumpState(reason);
        WPFRepairChain_(2);
        return;
    }
    WPFLog(@"界面确认为正常，本次不修");
}


// ===== 生命周期埋点 =====
static void WPFOnDidFinishLaunching(void) {
    UIApplication *app = [UIApplication sharedApplication];
    // 关键判据：用户点图标启动时这里是 Inactive；被 SBSLaunch(flag=1) 后台拉起时这里是 Background
    gWasHeadless = (app.applicationState == UIApplicationStateBackground);
    const char *ap = getenv("ActivePrewarm");
    const char *xpc = getenv("XPC_SERVICE_NAME");
    WPFLog(@"==== dylib loaded: bundle=%@ ====", [[NSBundle mainBundle] bundleIdentifier]);
    WPFLog(@"didFinishLaunching: appState=%ld headless=%d ActivePrewarm=%s XPC=%s",
           (long)app.applicationState, gWasHeadless, ap ? ap : "(null)", xpc ? xpc : "(null)");
    if (!kWPFEnable) return;
    if (!gWasHeadless) WPFLog(@"非后台启动，本次完全不干预（只观察）");
}

static void WPFOnWillEnterForeground(void) {
    if (gEnteredFG) return;
    gEnteredFG = YES;
    WPFLog(@"willEnterForeground（首次）");
}

static void WPFOnDidBecomeActive(void) {
    UIApplication *app = [UIApplication sharedApplication];
    WPFLog(@"didBecomeActive: appState=%ld headless=%d 已检查%d次/生效L%d",
           (long)app.applicationState, gWasHeadless, gCheckCount, gRepairLevel);
    if (!kWPFEnable || !gWasHeadless) return;
    // ⭐ v2.0.17：以前这里是 `gHandled` 一次性闸门 —— 只有进程的「第一次」前台激活会检查，
    // 之后所有 didBecomeActive 直接 return。可黑屏恰恰发生在用户后续点开的时候：
    // v2.0.16 日志里 pid 10806 后面 6 次 `handled=1` 的激活全部零检查，等于毫无保护。
    // 现在每次真前台激活都给一次机会，只做节流（间隔 1s、每进程最多 kWPFCheckMax 次）。
    if (app.applicationState != UIApplicationStateActive) return;
    if (gCheckCount >= kWPFCheckMax) {
        WPFLog(@"本进程检查次数已满（%d），不再检查", gCheckCount);
        return;
    }
    struct timeval tv; gettimeofday(&tv, NULL);
    double now = tv.tv_sec + tv.tv_usec / 1e6;
    if (gLastCheckAt > 0 && now - gLastCheckAt < 1.0) {
        WPFLog(@"激活过于频繁（%.2fs），跳过本次检查", now - gLastCheckAt);
        return;
    }
    gLastCheckAt = now;
    gCheckCount++;
    gCheckRetries = 0;
    double delay = (gCheckCount == 1) ? kWPFCheckDelay : 0.15;   // 首次等界面建好，后续快速复核
    WPFLog(@"前台激活 #%d，%.2fs 后检查界面健康度", gCheckCount, delay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WPFDoCheck(@"前台激活"); });
}

static void WPFOnEnterBackground(void) {
    WPFLog(@"didEnterBackground: appState=%ld", (long)[UIApplication sharedApplication].applicationState);
}

// ============================================================
// v2.0.21 ①：从源头掐掉「SubScene」这个持久化场景会话
// ------------------------------------------------------------
// 2026-11-07 03:37 设备取证（决定性证据）：
//   <容器>/Library/Saved Application State/com.tencent.xin.savedState/
//        KnownSceneSessions/data.data   （741 字节 bplist）
//   → 里面只有一个 key：5FCC1B2B-BAF9-4EFC-8A78-14A86E333179
//   → 值是 UISceneSession 的 NSKeyedArchiver，明确写着：
//        _UISceneConfigurationName = "SubScene"
//        _UISceneSessionRole       = UIWindowSceneSessionRoleApplication
//   也就是说这个 session 的**配置名是 SubScene** → 微信
//   application:configurationForConnectingSceneSession:options: 按配置名返回
//   MMSubSceneDelegate（它天然不建主界面，只有一个 hidden 的 MMSubSceneWindow）。
//   系统每次启动都把这个 session 恢复出来、并且**激活成前台** → 前台是个空场景 → 黑屏。
//   而 scenes=1 的那 13 次正常，就是这次没恢复它。
//   ⚠️ 这也解释了为什么它永远固定是同一个 UUID（其他 main session 每次都是新的）。
//
// 修法：本 dylib 的 constructor 在 UIApplicationMain **之前**执行（dyld 阶段），
//   此时 UIKit 还没读这个文件。把带 "SubScene" 的条目删掉再写回，系统就没有可恢复的
//   子场景，只能新建默认 session → MMMainSceneDelegate → 界面正常。
//   原文备份 data.data.wcvk.bak（只备份一次，便于回滚）。
static void WPFSanitizeKnownSceneSessions(void) {
    @try {
        NSString *home = NSHomeDirectory();
        NSString *bid  = [NSBundle mainBundle].bundleIdentifier;
        if (!home.length || !bid.length) { WPFLog(@"scene-session: HOME/bid 取不到，跳过"); return; }
        NSString *dir  = [home stringByAppendingPathComponent:
                          [NSString stringWithFormat:
                           @"Library/Saved Application State/%@.savedState/KnownSceneSessions", bid]];
        NSString *path = [dir stringByAppendingPathComponent:@"data.data"];
        NSData *raw = [NSData dataWithContentsOfFile:path];
        if (!raw.length) { WPFLog(@"scene-session: 没有 KnownSceneSessions/data.data，跳过"); return; }

        NSString *bak = [path stringByAppendingString:@".wcvk.bak"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:bak]) [raw writeToFile:bak atomically:NO];

        NSError *err = nil;
        NSPropertyListFormat fmt = 0;
        id pl = [NSPropertyListSerialization propertyListWithData:raw
                                                          options:NSPropertyListMutableContainersAndLeaves
                                                           format:&fmt error:&err];
        if (![pl isKindOfClass:[NSMutableDictionary class]]) {
            WPFLog(@"scene-session: plist 解析失败(%@)，直接删文件让系统重建", err.localizedDescription);
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            return;
        }
        NSMutableDictionary *d = (NSMutableDictionary *)pl;
        NSArray *keys = [d.allKeys copy];

        // ★★ v2.0.22 判据重写（v2.0.21 的「按配置名找 SubScene」是错的，实测从没删过一条）：
        //   实机证据（03:47~03:49 日志）：磁盘上唯一那条 D6C3661C 的配置名是 **MainScene**，
        //   可运行时它却被挂成 delegate=MMSubSceneDelegate / MMSubSceneWindow(hidden) ——
        //   而另一个**临时新 UUID** 的 session 才是 MMMainSceneDelegate / iConsoleWindow。
        //   也就是说「谁是 main」不是写死在配置名里，而是微信在
        //   application:configurationForConnectingSceneSession:options: 里动态分的，
        //   同一个 UUID 这次是 main、下次可能是 sub。
        //   ⇒ 唯一站得住的判据是**条数**：KnownSceneSessions 里只允许存在 1 条。
        //     多条 = 每次强杀（CocoaTop/SIGKILL，不走正常退出清理）+ 每次后台重拉
        //     各留一条，系统启动时按其中一条恢复，命中 sub 就黑屏 —— 条数越多越容易黑。
        //   做法：挑一条「配置名不是 SubScene」的留下，其余全部删除；若留下的那条本身
        //     就是 SubScene（磁盘上全是子场景），就一条都不留，让 UIKit 自己重建默认 session。
        NSData *needle = [@"SubScene" dataUsingEncoding:NSUTF8StringEncoding];
        // ★★ v2.0.24（04:15~04:16 实机证据）：判据改成**全删**，一条都不留。
        //   证据链：
        //     04:15:56.088 首次分配 session=FD5F03B1 name=MainScene → 正常（这是 FBS 的启动请求）
        //     04:16:05.855 9.7s 后系统又来一次分配 session=7E94B89B name=SubScene
        //                  ← 这条正是磁盘上被持久化、被系统"恢复"的那个 session
        //                  （本进程 ctor 里打印的就是「已存在 session 7E94B89B → 保留（唯一）」）
        //   结论：只要磁盘上留着任何一条被恢复的 session，用户点开时系统就连它，
        //         而微信对"恢复来的 session"一律下发 SubScene 配置 → 空场景占前台 → 黑屏。
        //   v2.0.22「留一条最像 main 的」不够：那条留下的照样会在运行时被当成 sub。
        //   ⇒ 幂等做法：每次启动前把 KnownSceneSessions 清空（原文件已备份 .wcvk.bak），
        //     系统没有可恢复的 session，只能按当前请求新建，微信才会老老实实分配 MainScene。
        NSString *keep = nil;
        NSMutableArray *kill = [NSMutableArray array];
        for (NSString *k in keys) {
            id v = d[k];
            BOOL isSub = NO;
            if ([v isKindOfClass:[NSData class]] && [(NSData *)v length]) {
                NSData *vd = (NSData *)v;
                isSub = [vd rangeOfData:needle options:0 range:NSMakeRange(0, vd.length)].location != NSNotFound;
            }
            WPFLog(@"scene-session: 已存在 session %@ → %@", k,
                   isSub ? @"SubScene（删）" : @"也删（v2.0.24 全清，防止运行时被当成 sub）");
            [kill addObject:k];
        }
        if (!kill.count) { WPFLog(@"scene-session: 本来就没有条目，无需处理"); return; }
        [d removeObjectsForKeys:kill];
        NSData *out = [NSPropertyListSerialization dataWithPropertyList:d
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0 error:&err];
        if (!out) { WPFLog(@"scene-session: 序列化失败(%@)", err.localizedDescription); return; }
        if ([out writeToFile:path atomically:YES]) {
            WPFLog(@"scene-session: 已清空 %lu 条会话（原 %lu 字节 → 新 %lu 字节），本次系统只能新建 session",
                   (unsigned long)kill.count, (unsigned long)raw.length, (unsigned long)out.length);
        } else {
            WPFLog(@"scene-session: 写回失败（路径 %@）", path);
        }
    } @catch (NSException *e) { WPFLog(@"scene-session 异常: %@", e.reason); }
}

// ============================================================
// v2.0.21 ②：绕开「当前设备不支持多个场景」这道门槛
// ------------------------------------------------------------
// 微信 Info.plist 里**没有** UIApplicationSceneManifest（已用 plutil 核过，grep 零命中），
// 所以 UIKit 认为 UIApplicationSupportsMultipleScenes = NO，
// 于是 requestSceneSessionActivation: / requestSceneSessionDestruction: 一律**同步**回调
//   "当前设备不支持多个场景。" (UISceneErrorDomain)  ← v2.0.19 / v2.0.20 实测都是它。
// 这就是 L3 三级全灭的原因：API 根本没执行，只在门口被拒。
// 做法：把 UIApplication / UISceneSession / UISceneConfiguration /
//       UIApplicationSceneManifest 上所有名字含 "MultipleScenes" 的 BOOL getter 改成返回 YES。
//       这几个 API 才有机会真正下到系统层。
static BOOL WPFYesIMP(id self, SEL _cmd) { return YES; }

static void WPFUnlockMultiScene(void) {
    const char *names[] = { "UIApplication", "UISceneSession",
                            "UISceneConfiguration", "UIApplicationSceneManifest" };
    int hacked = 0, seen = 0;
    for (int i = 0; i < 4; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) { WPFLog(@"multi-scene: 设备上没有类 %s", names[i]); continue; }
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int j = 0; j < n; j++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[j]));
            if ([sel rangeOfString:@"MultipleScenes" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            seen++;
            const char *rt = method_getTypeEncoding(ms[j]);
            BOOL isBool = (rt && (rt[0] == 'c' || rt[0] == 'B'));
            WPFLog(@"multi-scene: 命中 -[%s %@] 返回类型=%s%s", names[i], sel, rt ? rt : "?",
                   isBool ? " → 改写成 YES" : "（非 BOOL，跳过）");
            if (isBool) { method_setImplementation(ms[j], (IMP)WPFYesIMP); hacked++; }
        }
        free(ms);
    }
    WPFLog(@"multi-scene: 共命中 %d 个、改写 %d 个（改写 0 个 = 找不到门槛，scene API 仍会被拒）", seen, hacked);
}

// ============================================================
// v2.0.22 ③：把「子场景」分支掰回微信主场景（真正对症的一级）
// ------------------------------------------------------------
// 实机证据（v2.0.21 日志 03:47:43 / 03:47:55 / 03:48:17 三次黑屏）：
//   前台 scene → delegate=MMSubSceneDelegate、window=MMSubSceneWindow(hidden)、rootVC=nil、可用=0
//   主窗口 iConsoleWindow（rootVC=MainTabBarViewController）挂在**另一条** session 上 state=2（后台）
//   ⇒ 黑屏不是「窗口没了」，是**前台被空子场景占着**，主窗口在后台场景里没资格上屏。
//   系统级 scene 切换 API 在单场景 App 上一律同步被拒（v2.0.19/20/21 三版实证），
//   所以只能在**微信决定这条 session 用哪套 delegate 的那一刻**下手：
//   微信的 -application:configurationForConnectingSceneSession:options: 返回 UISceneConfiguration，
//   其中的 delegateClass 决定了这条 session 是主场景还是子场景。
//   hook 它：只要 delegateClass / name 里带 "SubScene"，就换成 MMMainSceneDelegate + "MainScene"，
//   让微信自己走**原生主界面分支**。
//   ⚠️ 边界：不自造窗口、不搬 windowScene、不伪造生命周期；用的仍是微信原生
//      MMMainSceneDelegate + iConsoleWindow + MainTabBarViewController，
//      只是把「被错分到子场景的那条 session」还原成它本来该有的主场景身份。
//   找不到 hook 点（微信升级改名）就只打日志、不做任何动作。
static Class gWPFFallbackMainSceneClass = Nil;
static IMP   gWPFOrigConfigForConnecting = NULL;

static id WPFConfigForConnecting(id self, SEL _cmd, id app, id session, id options) {
    // ⚠️ 先写一条「进入」日志再调原始实现：万一后面崩，至少能证明方法确实被调用了
    @autoreleasepool {
        NSString *pid = @"?";
        @try { pid = [NSString stringWithFormat:@"%@", [session valueForKey:@"persistentIdentifier"]]; }
        @catch (NSException *e) {}
        WPFLog(@"scene-config: → 进入分配（session=%@）", pid);
    }
    id cfg = nil;
    if (gWPFOrigConfigForConnecting) {
        cfg = ((id (*)(id, SEL, id, id, id))gWPFOrigConfigForConnecting)(self, _cmd, app, session, options);
    }
    @try {
        if (!cfg) { WPFLog(@"scene-config: 原始实现返回 nil"); return cfg; }
        NSString *cname = nil;
        Class dc = Nil;
        @try { cname = (NSString *)[cfg valueForKey:@"name"]; } @catch (NSException *e) {}
        @try { dc = (Class)[cfg valueForKey:@"delegateClass"]; } @catch (NSException *e) {}
        NSString *dcn = dc ? NSStringFromClass(dc) : @"(nil)";
        BOOL isSub = ([dcn rangeOfString:@"SubScene" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     (cname && [cname rangeOfString:@"SubScene" options:NSCaseInsensitiveSearch].location != NSNotFound);
        WPFLog(@"scene-config: 分配结果 name=%@ delegate=%@ → %@",
               cname ?: @"(nil)", dcn, isSub ? @"子场景(要掰回)" : @"主场景(不动)");
        if (isSub && gWPFFallbackMainSceneClass) {
            SEL setDC = NSSelectorFromString(@"setDelegateClass:");
            if ([cfg respondsToSelector:setDC]) {
                ((void (*)(id, SEL, Class))objc_msgSend)(cfg, setDC, gWPFFallbackMainSceneClass);
            } else {
                @try { [cfg setValue:gWPFFallbackMainSceneClass forKey:@"delegateClass"]; } @catch (NSException *e) {}
            }
            @try { [cfg setValue:@"MainScene" forKey:@"name"]; } @catch (NSException *e) {}
            WPFLog(@"scene-config: ★ 已掰回主场景（delegate=%@, name=MainScene）",
                   NSStringFromClass(gWPFFallbackMainSceneClass));
        }
    } @catch (NSException *e) { WPFLog(@"scene-config 异常: %@", e.reason); }
    return cfg;
}

// ⚠️⚠️ v2.0.22 首版事故复盘（2026-11-07 04:01~04:04 实机）：
//   首版是「全类扫描 + 批量接管」——扫到 11 个类实现了该方法，把其中 9 个的 IMP 全换成
//   同一个 WPFConfigForConnecting，但 gWPFOrigConfigForConnecting **只存了第一个类的原始实现**。
//   于是 UIKit 真去调 MicroMessengerAppDelegate 的那个方法时，跳进去执行的是**别的类**的实现，
//   参数语义完全对不上 → EXC_BAD_ACCESS。后果：微信启动后 1~3 秒必死，
//   日志里从 04:01:48 起连一次 willEnterForeground 都没有（v2.0.21 时期每进程都能进前台）。
//   ⇒ 现在只认准 MicroMessengerAppDelegate 一个类，其余（WCColorProxy / FakeTarget /
//     MMHookUIAlertView / SwiftUI.* 等别家插件或系统类）**一律不碰**，也算顺手避免破坏别人。
// 只取「这个类**自己**实现的方法」，绝不沿继承链拿父类的 Method。
// ⚠️ 这是 v2.0.22 崩溃的直接教训：class_getInstanceMethod 会沿继承链返回父类的 Method，
//   对它做 method_setImplementation 等于**改父类**，所有子类跟着遭殃。
static Method WPFMethodOwnedByClass(Class c, SEL sel) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    Method found = NULL;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(ms[i]) == sel) { found = ms[i]; break; }
    }
    if (ms) free(ms);
    return found;
}

static void WPFForceMainScene(void) {
    Class mainCls = NSClassFromString(@"MMMainSceneDelegate");
    if (!mainCls) { WPFLog(@"scene-config: 找不到 MMMainSceneDelegate 类，跳过"); return; }
    gWPFFallbackMainSceneClass = mainCls;

    Class appDel = NSClassFromString(@"MicroMessengerAppDelegate");
    if (!appDel) { WPFLog(@"scene-config: 找不到 MicroMessengerAppDelegate，跳过"); return; }

    SEL sel = sel_registerName("application:configurationForConnectingSceneSession:options:");
    // 沿继承链找**真正自己拥有**这个方法的那一层（AppDelegate 通常自己实现，
    // 若它只是继承，就动父类那一个 Method —— 而那个父类就是 UIKit 实际调用的目标）
    Class owner = Nil;
    Method m = NULL;
    for (Class c = appDel; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        Method om = WPFMethodOwnedByClass(c, sel);
        if (om) { owner = c; m = om; break; }
    }
    if (!m) {
        WPFLog(@"scene-config: AppDelegate 继承链上没人实现 %@，跳过", NSStringFromSelector(sel));
        return;
    }
    const char *te = method_getTypeEncoding(m);
    if (!te || te[0] != '@') {
        WPFLog(@"scene-config: %@ 的返回类型不是对象(%s)，放弃 hook 以免崩",
               NSStringFromClass(owner), te ?: "(null)");
        return;
    }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)WPFConfigForConnecting) { WPFLog(@"scene-config: 已接管过，跳过"); return; }
    gWPFOrigConfigForConnecting = method_setImplementation(m, (IMP)WPFConfigForConnecting);
    WPFLog(@"scene-config: 已接管 %@ 的 scene 配置方法（orig 就是它自己的实现）",
           NSStringFromClass(owner));
}

// ⚠️ 这里必须用 `__attribute__((constructor))`，**不能用 Logos 的 %ctor**（v2.0.15 根因）：
//   本文件历史上是 .xm + %ctor，编出来的 dylib 是**空壳** —— 实测该产物
//   __TEXT 段只剩 Mach-O 头（16384B）、__LINKEDIT 仅 1104B、全文件只有 18 个字符串
//   （连 "UIApplication" 都没有），链接阶段还报 `warning: no debug symbols in executable`。
//   也就是说 %ctor 的代码从来没被链进去 → 注入后什么都不可能执行 → 日志当然一条都没有。
//   同工程 wetypekeepalive（SBKeepAlive.xm）一直正常，差别只有一个：它用的是
//   __attribute__((constructor))，不经过 Logos。本文件没有任何 %hook/%orig，
//   本来就不需要 Logos，所以直接改成 .m + constructor，彻底绕开这条路。
__attribute__((constructor))
static void WCVKPFInit(void) {
    @autoreleasepool {
        // ★ 通道 D：第一件事就告诉 SpringBoard「我被加载并执行了」。
        //   darwin notify 不经过文件系统，沙盒写不写得出东西都跟它无关，
        //   所以它是「dylib 到底有没有被 dlopen 进来」的唯一硬证据：
        //   wetypekeepalive（SB 侧）收到会写 /var/mobile/wetypekeepalive.log 的 [PREWARM] ctor reached。
        notify_post("com.wcvoicekeep.prewarm.ctor");

        WPFLog(@"==== WCPrewarmFix inject (pid=%d build=%s) ====", getpid(), WCVK_BUILD_TAG);
        WPFLog(@"env: HOME=%s ActivePrewarm=%s XPC=%s",
               getenv("HOME") ?: "(null)",
               getenv("ActivePrewarm") ?: "(null)",
               getenv("XPC_SERVICE_NAME") ?: "(null)");
        // log channel / probe 两行由 WPFWriteFile 在首次成功写入时自动补上（含每个候选的 errno）

        // ★★ v2.0.21 两件必须在这里做的事（ctor 早于 UIApplicationMain）：
        //   ① 把持久化的 SubScene 场景会话从磁盘删掉 —— UIKit 还没读，删了就不会被恢复/激活
        //   ② 绕开「不支持多个场景」门槛 —— 否则后面的 scene API 全在门口被拒
        // ★★ v2.0.22 ③ 必须在 ctor 里（早于第一个 scene 连接）：接管
        //   application:configurationForConnectingSceneSession:options:，把子场景掰回主场景
        WPFSanitizeKnownSceneSessions();
        WPFUnlockMultiScene();
        WPFForceMainScene();

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) { WPFOnDidFinishLaunching(); }];
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) { WPFOnWillEnterForeground(); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) { WPFOnDidBecomeActive(); }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) { WPFOnEnterBackground(); }];
    }
}
