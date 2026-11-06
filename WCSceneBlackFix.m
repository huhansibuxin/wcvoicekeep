//
//  WCSceneBlackFix.m
//  见 WCSceneBlackFix.h 的说明。本文件不依赖 Logos / CydiaSubstrate，只用 UIKit + objc runtime，
//  可以直接放进任何 Theos tweak 工程（Makefile 里把 .m 加进 xxx_FILES 即可）。
//

#import "WCSceneBlackFix.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
//  日志
// ============================================================
static void (^gWCFLogHandler)(NSString *) = nil;

static void WCFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gWCFLogHandler) gWCFLogHandler(s);
    else NSLog(@"[SceneBlackFix] %@", s);
}

void WCSceneBlackFixSetLog(void (^handler)(NSString *line)) {
    gWCFLogHandler = [handler copy];
}

static BOOL gWCFRewriteConfig = YES;
void WCSceneBlackFixSetRewriteConfig(BOOL on) { gWCFRewriteConfig = on; }

static BOOL gWCFInstalled = NO;

// 搬家前主窗口所在的 scene，兜底路径失败时回滚用
static UIWindowScene *gWCFSavedMainScene = nil;

// ============================================================
//  窗口 / 场景工具
// ============================================================

static UIWindowScene *WCFActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback && s.activationState == UISceneActivationStateForegroundInactive) {
            fallback = (UIWindowScene *)s;
        }
    }
    return fallback;
}

/// 找 App 的主窗口：delegate.window → keyWindow → 扫全量挑「最像主界面」的那个。
/// 「最像」的判据：rootVC 名含 MainFrame / TabBar 优先，否则取 Normal 层里面积最大的。
static UIWindow *WCFMainWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    id d = app.delegate;
    if ([d respondsToSelector:@selector(window)]) {
        UIWindow *w = nil;
        @try { w = [d window]; } @catch (NSException *e) {}
        if ([w isKindOfClass:[UIWindow class]]) return w;
    }
    UIWindow *kw = nil;
    @try { kw = app.keyWindow; } @catch (NSException *e) {}
    if ([kw isKindOfClass:[UIWindow class]] && kw.rootViewController) return kw;

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

/// 这个 scene 上有几个「真的能在屏幕上显示」的窗口 = 黑屏与否的硬判据。
/// 空场景（系统恢复出来的 SubScene 被激活成前台）这里必然是 0。
static NSUInteger WCFUsableWindowCount(UIWindowScene *ws) {
    if (!ws) return 0;
    NSUInteger n = 0;
    for (UIWindow *w in ws.windows) {
        if (w.isHidden) continue;
        if (!w.rootViewController) continue;
        if (w.rootViewController.view.window != w) continue;
        if (w.bounds.size.width < 1 || w.bounds.size.height < 1) continue;
        n++;
    }
    return n;
}

static BOOL WCFSceneOnStage(UIWindow *w) {
    if (!w) return NO;
    UIWindowScene *ws = w.windowScene;
    if (!ws) return NO;
    UISceneActivationState st = ws.activationState;
    return (st == UISceneActivationStateForegroundActive ||
            st == UISceneActivationStateForegroundInactive);
}

/// 主窗口是否「结构完好并且在台上」。
/// 注意只做结构判定，不做像素快照：快照要在 Active 态才有意义，
/// 而本模块的处理时机恰恰常在 Inactive，靠 structure 就够精准了。
static BOOL WCFHealthy(UIWindow *w) {
    if (!w) return NO;
    if (w.isHidden || w.alpha < 0.01) return NO;
    if (w.bounds.size.width < 1 || w.bounds.size.height < 1) return NO;
    UIViewController *vc = w.rootViewController;
    if (!vc || !vc.view) return NO;
    if (vc.view.window != w) return NO;
    if (vc.view.bounds.size.width < 1 || vc.view.bounds.size.height < 1) return NO;
    return WCFSceneOnStage(w);
}

/// 只取「类自己实现的」方法，绝不沿继承链拿父类的 ——
/// method_setImplementation 改父类 Method 会波及所有子类，这是曾经崩过的坑。
static Method WCFMethodOwnedByClass(Class c, SEL sel) {
    if (!c || !sel) return NULL;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    if (!list) return NULL;
    Method found = NULL;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = list[i]; break; }
    }
    free(list);
    return found;
}

// ============================================================
//  核心：把主窗口搬到指定 scene（纯窗口层操作）
// ============================================================
static BOOL WCFMoveMainWindowToScene(UIWindow *main, UIWindowScene *target, BOOL saveForRollback) {
    if (!main || !target) return NO;
    UIWindowScene *from = main.windowScene;
    if (from == target) return NO;

    WCFLog(@"搬家: 主窗口 %p 从 scene %p(state=%ld) -> 目标 scene %p(state=%ld)",
           (__bridge void *)main,
           (__bridge void *)from, from ? (long)from.activationState : (long)-1,
           (__bridge void *)target, (long)target.activationState);
    if (saveForRollback) gWCFSavedMainScene = from;

    @try {
        main.windowScene = target;
    } @catch (NSException *e) {
        WCFLog(@"搬家异常: %@", e.reason);
        if (saveForRollback) gWCFSavedMainScene = nil;
        return NO;
    }

    @try {
        UIViewController *vc = main.rootViewController;
        BOOL appeared = NO;
        if (vc) {
            // 官方容器转场 API：只让 VC 重走一遍「出现」流程。
            // 少了这一步，窗口会亮但内容不重建（微信表现为通讯录空白 —— 曾经踩过）。
            // 不是伪造 UIApplication 通知，也不是手调 viewWillAppear。
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
        WCFLog(@"搬家完成: 主窗口 scene=%p(state=%ld) 可用窗口=%lu",
               (__bridge void *)main.windowScene,
               main.windowScene ? (long)main.windowScene.activationState : (long)-1,
               (unsigned long)WCFUsableWindowCount(main.windowScene));
    } @catch (NSException *e) {
        WCFLog(@"搬家布局异常: %@", e.reason);
    }
    return YES;
}

static void WCFRollbackMainScene(UIWindow *main) {
    if (!main || !gWCFSavedMainScene) return;
    WCFLog(@"搬家后仍黑，回滚主窗口到原 scene %p", (__bridge void *)gWCFSavedMainScene);
    @try {
        main.windowScene = gWCFSavedMainScene;
        [main setNeedsLayout];
        [main layoutIfNeeded];
    } @catch (NSException *e) { WCFLog(@"回滚异常: %@", e.reason); }
    gWCFSavedMainScene = nil;
}

// ============================================================
//  ① 核心：-scene:willConnectToSession:options: —— 抢在系统激活空场景之前搬窗口
// ============================================================
static IMP gWCFOrigWillConnect = NULL;

static void WCFWillConnectHook(id self, SEL _cmd, UIScene *scene, UISceneSession *session, id options) {
    // 先搬家，再调原实现 —— 必须赶在 scene 被激活成前台之前
    @try {
        if (scene && [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *main = WCFMainWindow();
            if (main) {
                if (main.windowScene != ws) {
                    WCFLog(@"willConnect: 新场景 %p(session=%@ state=%ld) 即将连接，主窗口在 %p -> 抢先搬家",
                           (__bridge void *)ws,
                           session.persistentIdentifier ?: @"(nil)",
                           (long)ws.activationState,
                           (__bridge void *)main.windowScene);
                    WCFMoveMainWindowToScene(main, ws, NO);
                }
            } else {
                // 首次启动，主窗口还没建，交给 App 自己在这一轮的 willConnect 里创建
                WCFLog(@"willConnect: 新场景 %p 连接，主窗口还没建（首次启动），不介入",
                       (__bridge void *)ws);
            }
        }
    } @catch (NSException *e) { WCFLog(@"willConnect 抢先搬家异常: %@", e.reason); }

    if (gWCFOrigWillConnect) {
        ((void (*)(id, SEL, id, id, id))gWCFOrigWillConnect)(self, _cmd, scene, session, options);
    }

    // App 自己的实现可能又改窗口归属（它内部也有窗口管理），orig 之后再校准一次
    @try {
        if (scene && [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *main2 = WCFMainWindow();
            if (main2 && main2.windowScene != ws &&
                ws.activationState != UISceneActivationStateBackground) {
                WCFLog(@"willConnect: orig 之后主窗口又不在这个场景上了 -> 再搬一次");
                WCFMoveMainWindowToScene(main2, ws, NO);
            }
        }
    } @catch (NSException *e) { WCFLog(@"willConnect 复查异常: %@", e.reason); }
}

/// 装 willConnect hook。
/// 只接管**第一个**真正拥有该方法的类（实测微信走的就是主 scene delegate 这一个），
/// 其余一律不动 —— 多个类各自实现时如果共用同一个 orig，就会 unrecognized selector 崩溃。
static void WCFInstallWillConnectHook(void) {
    SEL sel = sel_registerName("scene:willConnectToSession:options:");

    // 优先按已知的微信 scene delegate 类名找
    NSArray *candidates = @[@"MMMainSceneDelegate", @"MMSceneDelegate",
                            @"MMSubSceneDelegate", @"MMProxySceneDelegate"];
    NSMutableArray *pool = [NSMutableArray array];
    for (NSString *n in candidates) {
        Class c = NSClassFromString(n);
        if (c) [pool addObject:c];
    }
    // 找不到候补（换 App / 类名变了）才扫全类，且跳过所有系统类 ——
    // 宁可这次不装（还有兜底），也不去改 UIKit 内部实现。
    if (pool.count == 0) {
        int total = objc_getClassList(NULL, 0);
        if (total > 0) {
            Class *all = (Class *)malloc(sizeof(Class) * (size_t)total);
            if (all) {
                total = objc_getClassList(all, (int)total);
                for (int i = 0; i < total; i++) {
                    Class c = all[i];
                    if (!c) continue;
                    NSString *cn = NSStringFromClass(c);
                    if (!cn.length) continue;
                    if ([cn hasPrefix:@"UI"] || [cn hasPrefix:@"_UI"] ||
                        [cn hasPrefix:@"NS"] || [cn hasPrefix:@"_NS"] ||
                        [cn hasPrefix:@"CA"] || [cn hasPrefix:@"Swift"]) continue;
                    [pool addObject:c];
                }
                free(all);
            }
        }
        WCFLog(@"willConnect: 候选类都不存在，改为全类扫描（已排除系统类），候选 %lu 个", (unsigned long)pool.count);
    }

    for (Class c in pool) {
        // 沿继承链找到真正拥有这个方法的类
        Class owner = Nil;
        Method m = NULL;
        for (Class k = c; k && k != [NSObject class]; k = class_getSuperclass(k)) {
            Method om = WCFMethodOwnedByClass(k, sel);
            if (om) { owner = k; m = om; break; }
        }
        if (!m) continue;
        const char *te = method_getTypeEncoding(m);
        if (!te || te[0] != 'v') {
            WCFLog(@"willConnect: %@ 返回类型不是 void(%s)，跳过", NSStringFromClass(owner), te ?: "?");
            continue;
        }
        if (method_getImplementation(m) == (IMP)WCFWillConnectHook) return;   // 已装过
        gWCFOrigWillConnect = method_setImplementation(m, (IMP)WCFWillConnectHook);
        WCFLog(@"willConnect: 已接管 %@（orig 就是它自己的实现）", NSStringFromClass(owner));
        return;   // 只接管一个
    }
    WCFLog(@"willConnect: 没找到可接管的实现，抢先搬家不可用（仍有 0.4s 兜底）");
}

// ============================================================
//  ② 可选：-application:configurationForConnectingSceneSession:options:
//     把 SubScene 配置改写回 MainScene，让 App 走自己的主界面分支
// ============================================================
static Class gWCFMainSceneDelegateClass = Nil;
static IMP   gWCFOrigConfigForConnecting = NULL;

static id WCFConfigForConnecting(id self, SEL _cmd, id app, id session, id options) {
    id cfg = nil;
    if (gWCFOrigConfigForConnecting) {
        cfg = ((id (*)(id, SEL, id, id, id))gWCFOrigConfigForConnecting)(self, _cmd, app, session, options);
    }
    @try {
        if (!cfg || !gWCFRewriteConfig) return cfg;
        NSString *cname = nil;
        Class dc = Nil;
        @try { cname = (NSString *)[cfg valueForKey:@"name"]; } @catch (NSException *e) {}
        @try { dc = (Class)[cfg valueForKey:@"delegateClass"]; } @catch (NSException *e) {}
        NSString *dcn = dc ? NSStringFromClass(dc) : @"(nil)";

        BOOL isSub = ([dcn rangeOfString:@"SubScene" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                     (cname && [cname rangeOfString:@"SubScene" options:NSCaseInsensitiveSearch].location != NSNotFound);
        WCFLog(@"scene-config: 分配 name=%@ delegate=%@ -> %@",
               cname ?: @"(nil)", dcn, isSub ? @"子场景(要掰回)" : @"主场景(不动)");

        if (isSub && gWCFMainSceneDelegateClass) {
            SEL setDC = NSSelectorFromString(@"setDelegateClass:");
            if ([cfg respondsToSelector:setDC]) {
                ((void (*)(id, SEL, Class))objc_msgSend)(cfg, setDC, gWCFMainSceneDelegateClass);
            } else {
                @try { [cfg setValue:gWCFMainSceneDelegateClass forKey:@"delegateClass"]; } @catch (NSException *e) {}
            }
            @try { [cfg setValue:@"MainScene" forKey:@"name"]; } @catch (NSException *e) {}
            WCFLog(@"scene-config: 已掰回主场景（delegate=%@, name=MainScene）",
                   NSStringFromClass(gWCFMainSceneDelegateClass));
        }
    } @catch (NSException *e) { WCFLog(@"scene-config 异常: %@", e.reason); }
    return cfg;
}

static void WCFInstallConfigHook(void) {
    Class mainCls = NSClassFromString(@"MMMainSceneDelegate");
    if (!mainCls) { WCFLog(@"scene-config: 没有 MMMainSceneDelegate，跳过改写"); return; }
    gWCFMainSceneDelegateClass = mainCls;

    SEL sel = sel_registerName("application:configurationForConnectingSceneSession:options:");
    // 只从 AppDelegate 沿继承链找拥有者
    Class owner = Nil;
    Method m = NULL;
    for (Class c = NSClassFromString(@"MicroMessengerAppDelegate"); c && c != [NSObject class]; c = class_getSuperclass(c)) {
        Method om = WCFMethodOwnedByClass(c, sel);
        if (om) { owner = c; m = om; break; }
    }
    if (!m) { WCFLog(@"scene-config: 没找到 AppDelegate 的实现，跳过改写"); return; }
    const char *te = method_getTypeEncoding(m);
    if (!te || te[0] != '@') {
        WCFLog(@"scene-config: 返回类型不是对象(%s)，放弃以免崩", te ?: "(null)");
        return;
    }
    if (method_getImplementation(m) == (IMP)WCFConfigForConnecting) return;
    gWCFOrigConfigForConnecting = method_setImplementation(m, (IMP)WCFConfigForConnecting);
    WCFLog(@"scene-config: 已接管 %@ 的 scene 配置方法", NSStringFromClass(owner));
}

// ============================================================
//  ③ 兜底：didBecomeActive 后 0.4s 结构检查
// ============================================================
static double const kWCFCheckDelay  = 0.4;    // 首次前台激活后多久检查
static double const kWCFVerifyDelay = 0.35;   // 搬完多久复查
static int    const kWCFMaxFix      = 6;      // 同一进程最多修几次（用户反复点开每次都要能修）

static int gWCFFixCount = 0;

static void WCFCheck(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *main = WCFMainWindow();
    if (!main) { WCFLog(@"兜底检查: 没有主窗口，跳过"); return; }

    UIWindowScene *front = WCFActiveScene();
    NSUInteger frontUsable = WCFUsableWindowCount(front);
    BOOL onStage = WCFSceneOnStage(main);

    WCFLog(@"兜底检查: mainWindow=%@ onStage=%d 前台scene=%p(state=%ld) 前台可用窗口=%lu 全部窗口=%lu",
           NSStringFromClass([main class]), onStage ? 1 : 0,
           (__bridge void *)front, front ? (long)front.activationState : (long)-1,
           (unsigned long)frontUsable,
           (unsigned long)app.windows.count);

    if (WCFHealthy(main)) { WCFLog(@"兜底检查: 界面正常，不动"); return; }

    // 唯一处理的黑屏形态：前台是个空场景，而主窗口挂在别的 scene 上
    BOOL emptyForeground = (front != nil) && (frontUsable == 0) && (main.windowScene != front);
    if (!emptyForeground) {
        WCFLog(@"兜底检查: 不是「前台空场景」形态，不介入（结构与 onStage=%d）", onStage ? 1 : 0);
        return;
    }
    if (gWCFFixCount >= kWCFMaxFix) {
        WCFLog(@"兜底检查: 本进程已修 %d 次，不再重复（防抖动）", gWCFFixCount);
        return;
    }
    gWCFFixCount++;

    WCFLog(@"兜底检查: 命中黑屏（前台空场景）-> 第 %d 次搬家", gWCFFixCount);
    if (!WCFMoveMainWindowToScene(main, front, YES)) {
        WCFLog(@"兜底检查: 搬家失败");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWCFVerifyDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *mw = WCFMainWindow();
        if (WCFHealthy(mw)) {
            WCFLog(@"兜底搬家成功：%.2fs 内界面恢复", kWCFVerifyDelay);
            return;
        }
        WCFRollbackMainScene(mw);
        WCFLog(@"兜底搬家后仍未恢复，已回滚");
    });
}

static void WCFOnDidBecomeActive(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWCFCheckDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WCFCheck(); });
}

// ============================================================
//  安装入口
// ============================================================
void WCSceneBlackFixInstall(void) {
    if (gWCFInstalled) return;
    gWCFInstalled = YES;

    WCFInstallConfigHook();       // ② 可选：掰回主场景配置
    WCFInstallWillConnectHook();  // ① 核心：抢在激活前搬窗口

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        WCFOnDidBecomeActive();   // ③ 兜底
    }];
    WCFLog(@"已安装（willConnect 抢先搬家 + 0.4s 兜底）");
}
