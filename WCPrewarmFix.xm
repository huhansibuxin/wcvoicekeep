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

// ===== 配置（先写死，实测后再按需做成 plist 开关）=====
static BOOL const kWPFEnable        = YES;   // 总开关
static BOOL const kWPFExitFallback  = YES;   // L1~L4 全失败时 exit(0) 兜底
static double const kWPFCheckDelay  = 1.0;   // 首次前台激活后多久检查
static double const kWPFRetryDelay  = 1.5;   // 兜底前最后复查延迟

// ===== 运行状态 =====
static BOOL gWasHeadless   = NO;   // 本次进程是后台无头启动的
static BOOL gHandled       = NO;   // 已经做过一次检查/修复
static BOOL gEnteredFG     = NO;   // 已经进过前台
static int  gRepairLevel   = 0;    // 实际生效的修复级别（0=没修）

// ===== 日志 =====
static NSString *WPFLogPath(void) {
    static NSString *p = nil;
    if (p) return p;
    @try {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = dirs.count ? dirs[0] : NSTemporaryDirectory();
        p = [dir stringByAppendingPathComponent:@"wcprewarm.log"];
    } @catch (NSException *e) {
        p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wcprewarm.log"];
    }
    return p;
}

static void WPFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@][%d] %@\n",
                      [df stringFromDate:[NSDate date]], getpid(), body];

    NSString *path = WPFLogPath();
    if (![path isKindOfClass:[NSString class]] || path.length < 2) return;   // dyld 早期路径可能还取不到
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
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

// 全量状态 dump（诊断核心：黑屏那一刻微信内部到底是什么样）
static void WPFDumpState(NSString *tag) {
    UIApplication *app = [UIApplication sharedApplication];
    WPFLog(@"---- STATE %@ ----", tag);
    WPFLog(@"appState=%ld delegate=%@ headless=%d enteredFG=%d",
           (long)app.applicationState, WPFClassChain(app.delegate), gWasHeadless, gEnteredFG);

    NSMutableString *sc = [NSMutableString string];
    for (UIScene *s in app.connectedScenes) {
        [sc appendFormat:@"%@(state=%ld) ", NSStringFromClass([s class]), (long)s.activationState];
    }
    WPFLog(@"scenes(%lu): %@", (unsigned long)app.connectedScenes.count, sc.length ? sc : @"(none)");

    NSArray<UIWindow *> *wins = app.windows;
    WPFLog(@"windows(%lu):", (unsigned long)wins.count);
    for (UIWindow *w in wins) {
        UIViewController *vc = w.rootViewController;
        NSString *vcs = vc ? NSStringFromClass([vc class]) : @"(nil)";
        NSString *winScene = w.windowScene ? NSStringFromClass([w.windowScene class]) : @"(nil)";
        WPFLog(@"  win %@ hidden=%d alpha=%.2f level=%.1f frame=%.0fx%.0f scene=%@ rootVC=%@ viewInWin=%d subviews=%lu",
               NSStringFromClass([w class]), (int)w.isHidden, w.alpha, w.windowLevel,
               w.bounds.size.width, w.bounds.size.height, winScene, vcs,
               (vc && vc.view.window == w) ? 1 : 0,
               (unsigned long)(vc ? vc.view.subviews.count : 0));
    }
    UIWindow *main = WPFMainWindow(app);
    WPFLog(@"mainWindow=%@ alive=%d", main ? NSStringFromClass([main class]) : @"(nil)",
           WPFWindowAlive(main) ? 1 : 0);
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
    UIWindow *w = WPFMainWindow(app);
    BOOL alive = WPFWindowAlive(w);
    WPFLog(@"检查(%@): mainWindow=%@ alive=%d", reason,
           w ? NSStringFromClass([w class]) : @"(nil)", alive ? 1 : 0);
    WPFDumpState(reason);
    if (alive) return;
    WPFLog(@"判定黑屏 -> 开始 L1~L4 逐级修复");
    WPFRepairChain_(1);
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

%ctor {
    @autoreleasepool {
        WPFLog(@"==== WCPrewarmFix inject (pid=%d) ====", getpid());
        WPFLog(@"env: ActivePrewarm=%s", getenv("ActivePrewarm") ?: "(null)");
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
