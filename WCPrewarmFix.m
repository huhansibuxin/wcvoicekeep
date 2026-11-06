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
#define WCVK_BUILD_TAG "v2.0.16-roothide"
static BOOL const kWPFEnable        = YES;   // 总开关
static BOOL const kWPFExitFallback  = YES;   // L1~L4 全失败时 exit(0) 兜底
static double const kWPFCheckDelay  = 1.0;   // 首次前台激活后多久检查
static double const kWPFRetryDelay  = 1.5;   // 兜底前最后复查延迟

// ===== 运行状态 =====
static BOOL gWasHeadless   = NO;   // 本次进程是后台无头启动的
static BOOL gHandled       = NO;   // 已经做过一次检查/修复
static BOOL gEnteredFG     = NO;   // 已经进过前台
static int  gRepairLevel   = 0;    // 实际生效的修复级别（0=没修）
static int  gCheckRetries  = 0;    // 非 Active 态复查次数（v2.0.16）

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

// ===== L1~L4 修复 =====
// 返回 YES = 这一级做过了（是否真修好由调用方复查）
static BOOL WPFRepairLevel1(UIWindow *w) {
    if (!w) return NO;
    WPFLog(@"L1: makeKeyAndVisible + 强制 layout + hidden 抖动");
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

static BOOL WPFRepairLevel2(UIWindow *w) {
    UIWindowScene *scene = WPFActiveScene();
    if (!w || !scene) { WPFLog(@"L2: 跳过（window 或前台 scene 缺失）"); return NO; }
    if (w.windowScene == scene) { WPFLog(@"L2: 已经是目标 scene，跳过"); return NO; }
    WPFLog(@"L2: 把 %@ 绑到 %@", NSStringFromClass([w class]), NSStringFromClass([scene class]));
    BOOL ok = NO;
    @try {
        if ([w respondsToSelector:NSSelectorFromString(@"setWindowScene:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(w, NSSelectorFromString(@"setWindowScene:"), scene);
            ok = YES;
        } else {
            [w setValue:scene forKey:@"windowScene"];   // KVC 走私有 ivar，兜底
            ok = YES;
        }
    } @catch (NSException *e) { WPFLog(@"L2 异常: %@", e.reason); }
    if (ok) {
        @try { [w makeKeyAndVisible]; [w layoutIfNeeded]; } @catch (NSException *e) {}
    }
    return ok;
}

static BOOL WPFRepairLevel3(UIWindow *w) {
    if (!w) return NO;
    UIViewController *vc = w.rootViewController;
    if (!vc) { WPFLog(@"L3: 跳过（根本没有 rootViewController）"); return NO; }
    WPFLog(@"L3: 重新挂 rootVC=%@ 并补 appear 回调", NSStringFromClass([vc class]));
    @try {
        w.rootViewController = vc;
        [vc viewWillAppear:NO];
        [vc viewDidAppear:NO];
        [vc.view setNeedsLayout];
        [vc.view layoutIfNeeded];
        [w makeKeyAndVisible];
    } @catch (NSException *e) { WPFLog(@"L3 异常: %@", e.reason); return NO; }
    return YES;
}

static BOOL WPFRepairLevel4(void) {
    UIApplication *app = [UIApplication sharedApplication];
    WPFLog(@"L4: 重放前台生命周期（通知 + delegate），逼微信自己把界面建起来");
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc postNotificationName:UIApplicationWillEnterForegroundNotification object:app];
        [nc postNotificationName:UIApplicationDidBecomeActiveNotification object:app];
        id d = app.delegate;
        if ([d respondsToSelector:@selector(applicationWillEnterForeground:)])
            ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationWillEnterForeground:), app);
        if ([d respondsToSelector:@selector(applicationDidBecomeActive:)])
            ((void (*)(id, SEL, id))objc_msgSend)(d, @selector(applicationDidBecomeActive:), app);
    } @catch (NSException *e) { WPFLog(@"L4 异常: %@", e.reason); return NO; }
    return YES;
}

// 逐级修复：每级做完等一会儿复查，修好立即停
static void WPFRepairChain_(int level);

static void WPFCheckAfterRepair(UIApplication *app, int nextLevel, int doneLevel) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = WPFMainWindow(app);
        BOOL alive = WPFWindowAlive(w);
        WPFLog(@"复查(L%d 之后): alive=%d", doneLevel, alive ? 1 : 0);
        if (alive) {
            gRepairLevel = doneLevel;
            WPFLog(@"*** 修复成功，生效级别 L%d ***", doneLevel);
            WPFDumpState(@"修复后");
            return;
        }
        if (nextLevel > 4) {
            WPFLog(@"*** L1~L4 全部无效 ***");
            WPFDumpState(@"修复失败");
            if (!kWPFExitFallback) { WPFLog(@"exitFallback 关闭，保持现状"); return; }
            // 最后再给一次机会：有些 App 是把界面重建排到下一个 runloop 之后的
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWPFRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIWindow *w2 = WPFMainWindow(app);
                BOOL alive2 = WPFWindowAlive(w2);
                WPFLog(@"最终复查: alive=%d", alive2 ? 1 : 0);
                if (alive2) { WPFLog(@"自己好了，不退出"); return; }
                WPFLog(@"!!! 界面确实起不来，exit(0) 让下次打开走冷启动 !!!");
                WPFDumpState(@"退出前");
                exit(0);
            });
            return;
        }
        WPFRepairChain_(nextLevel);
    });
}

static void WPFRepairChain_(int level) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *w = WPFMainWindow(app);
    BOOL did = NO;
    switch (level) {
        case 1: did = WPFRepairLevel1(w); break;
        case 2: did = WPFRepairLevel2(w); break;
        case 3: did = WPFRepairLevel3(w); break;
        case 4: did = WPFRepairLevel4();  break;
        default: did = NO; break;
    }
    if (!did) WPFLog(@"L%d 未执行（条件不满足）", level);
    WPFCheckAfterRepair(app, level + 1, level);
}

static void WPFDoCheck(NSString *reason) {
    UIApplication *app = [UIApplication sharedApplication];
    // 快照判定必须在 Active 态做：v2.0.15 日志里每次「1s 后检查」时 appState 已经从
    // Active(0) 掉回 Inactive(1)，这时候离屏渲染本来就是空的，判黑没有意义。
    if (app.applicationState != UIApplicationStateActive && gCheckRetries < 3) {
        gCheckRetries++;
        WPFLog(@"检查(%@): appState=%ld 非 Active，%.1fs 后复查（第 %d 次）",
               reason, (long)app.applicationState, kWPFRetryDelay, gCheckRetries);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWPFRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WPFDoCheck(reason); });
        return;
    }

    UIWindow *w = WPFMainWindow(app);
    BOOL alive  = WPFWindowAlive(w);
    BOOL staged = WPFSceneOnStage(w);
    WPFLog(@"检查(%@): mainWindow=%@ alive=%d sceneOnStage=%d appState=%ld", reason,
           w ? NSStringFromClass([w class]) : @"(nil)", alive ? 1 : 0, staged ? 1 : 0,
           (long)app.applicationState);
    WPFDumpState(reason);
    // 结构健康但 scene 不在台上（或压根没 scene）→ 一定是黑的，先修 scene
    if (!alive || !staged) {
        WPFLog(@"判定黑屏（结构/scene）-> 开始 L1~L4 逐级修复");
        WPFRepairChain_(1);
        return;
    }
    // 结构和 scene 都像样，最后用像素定死：真没画面才动
    if (WPFSnapshotBlank(w)) {
        WPFLog(@"判定黑屏（快照无画面）-> 开始 L1~L4 逐级修复");
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
    WPFLog(@"didBecomeActive: appState=%ld headless=%d handled=%d",
           (long)app.applicationState, gWasHeadless, gHandled);
    if (!kWPFEnable || !gWasHeadless || gHandled) return;
    // 只处理「后台无头拉起 → 第一次真正进前台」这一次
    if (app.applicationState != UIApplicationStateActive) return;
    gHandled = YES;
    WPFLog(@"首次前台激活，%.1fs 后检查界面健康度", kWPFCheckDelay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWPFCheckDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WPFDoCheck(@"首次前台激活"); });
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
