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
#define WCVK_BUILD_TAG "v2.0.20-roothide"
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
static double const kWPFCheckDelay  = 1.0;   // 首次前台激活后多久检查
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

static BOOL WPFRepairLevel3(UIWindow *w) {
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

    UIApplication *app = [UIApplication sharedApplication];
    @try {
        // 公开 API：请系统销毁这个 session。不传 options（不需要任何转场/快照行为）。
        [app requestSceneSessionDestruction:bad.session options:nil errorHandler:^(NSError *e) {
            WPFLog(@"L3: requestSceneSessionDestruction 失败: %@ (%@)", e.localizedDescription, e.domain);
        }];
        WPFLog(@"L3: 已请系统销毁该子场景 session");
    } @catch (NSException *e) {
        WPFLog(@"L3 异常: %@", e.reason);
        return NO;
    }

    // 销毁是异步的：0.9s 后若界面还没回来，再请系统激活 main session 一次
    // （此时只剩它一个 session，"不支持多场景"的拒绝条件已经不成立）
    NSString *mainSessionID = mainScene.session.persistentIdentifier;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *a = [UIApplication sharedApplication];
        UIWindow *mw = WPFMainWindow(a);
        if (WPFHealthy(mw, YES)) { WPFLog(@"L3: 拆完子场景后界面已恢复"); return; }
        UISceneSession *ms = mainScene.session;
        if (!ms) {
            for (UIScene *s in a.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                if (WPFUsableWindowCount((UIWindowScene *)s) > 0) { ms = s.session; break; }
            }
        }
        if (!ms) { WPFLog(@"L3: 兜底激活跳过（找不到可用的 main session）"); return; }
        WPFLog(@"L3: 兜底——请系统激活 main session %@", ms.persistentIdentifier ?: mainSessionID ?: @"(nil)");
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [a requestSceneSessionActivation:ms userActivity:nil options:nil errorHandler:^(NSError *e) {
                WPFLog(@"L3 兜底激活失败: %@", e.localizedDescription);
            }];
            #pragma clang diagnostic pop
        } @catch (NSException *e) { WPFLog(@"L3 兜底激活异常: %@", e.reason); }
    });

    return YES;
}

static BOOL WPFRepairLevel2(UIWindow *w) {
    if (!w) { WPFLog(@"L2: 跳过（没有主窗口）"); return NO; }
    if (gL2Attempts >= 1) { WPFLog(@"L2: 本进程已试过 %d 次，不再重复（防抖动）", gL2Attempts); return NO; }
    gL2Attempts++;

    UIWindowScene *owned = w.windowScene;          // 主窗口自己那个 scene（现在是后台态）
    UIWindowScene *front = WPFActiveScene();       // 系统当前认的前台 scene
    WPFLog(@"L2(%d): 主窗口 scene=%p(state=%ld) 前台 scene=%p(state=%ld)",
           gL2Attempts,
           (__bridge void *)owned, (long)owned.activationState,
           (__bridge void *)front, (long)front.activationState);

    // ② 让系统刷新该 scene（异步，UI 由微信自己重建）
    if (owned.session) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [([UIApplication sharedApplication]) requestSceneSessionRefresh:owned.session];
            #pragma clang diagnostic pop
            WPFLog(@"L2② 已请求系统刷新主窗口 scene（唯一保留的安全动作）");
        } @catch (NSException *e) { WPFLog(@"L2② 异常: %@", e.reason); }
    } else {
        WPFLog(@"L2② 跳过（主窗口没有 session）");
    }
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
        case 3: did = WPFRepairLevel3(w); break;
        default: did = NO; break;
    }
    if (!did) WPFLog(@"L%d 未执行（条件不满足）", level);
    WPFCheckAfterRepair(app, level + 1, level);
}

static void WPFDoCheck(NSString *reason) {
    UIApplication *app = [UIApplication sharedApplication];
    // 快照判定必须在 Active 态做：v2.0.15 日志里每次「1s 后检查」时 appState 已经从
    // Active(0) 掉回 Inactive(1)，这时候离屏渲染本来就是空的，判黑没有意义。
    if (app.applicationState != UIApplicationStateActive && gCheckRetries < kWPFRetryMax) {
        gCheckRetries++;
        WPFLog(@"检查(%@): appState=%ld 非 Active，%.1fs 后复查（第 %d/%d 次）",
               reason, (long)app.applicationState, kWPFRetryDelay, gCheckRetries, kWPFRetryMax);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWPFRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WPFDoCheck(reason); });
        return;
    }

    UIWindow *w = WPFTargetWindow(app);
    BOOL alive  = WPFWindowAlive(w);
    BOOL staged = WPFSceneOnStage(w);
    WPFLog(@"检查(%@): mainWindow=%@ alive=%d sceneOnStage=%d appState=%ld 已检查%d次/生效L%d",
           reason, w ? NSStringFromClass([w class]) : @"(nil)", alive ? 1 : 0, staged ? 1 : 0,
           (long)app.applicationState, gCheckCount, gRepairLevel);
    WPFDumpState(reason);

    // 窗口结构都不成立 → 从 L1 起
    if (!alive) {
        WPFLog(@"判定黑屏（窗口结构不成立）-> L1/L2 原生");
        WPFRepairChain_(1);
        return;
    }
    // ⭐ 结构完全健康、只是没挂在台上 → 这就是本机唯一的黑屏形态：
    //    系统把 MMMainSceneDelegate 的主场景压到后台，却把 MMSubSceneDelegate 的子场景
    //    激活成前台（上面只有一个 hidden 空窗口）。L1 无意义，从 L2 起，L2 无效再走 L3 拆子场景。
    if (!staged) {
        UIWindowScene *ms = nil;
        UIWindowScene *bad = WPFEmptyForegroundScene(&ms);
        WPFLog(@"判定黑屏（主界面在后台、前台是空场景=%d）-> 从 L2 起修，再走 L3",
               bad ? 1 : 0);
        WPFRepairChain_(2);
        return;
    }
    // 结构和 scene 都像样，最后用像素定死：真没画面才动
    if (WPFSnapshotBlank(w)) {
        WPFLog(@"判定黑屏（快照无画面）-> L1/L2 原生");
        WPFRepairChain_(1);
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
    double delay = (gCheckCount == 1) ? kWPFCheckDelay : 0.35;   // 首次等界面建好，后续快速复核
    WPFLog(@"前台激活 #%d，%.2fs 后检查界面健康度", gCheckCount, delay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WPFDoCheck(@"前台激活"); });
}

static void WPFOnEnterBackground(void) {
    WPFLog(@"didEnterBackground: appState=%ld", (long)[UIApplication sharedApplication].applicationState);
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
