//
//  WCSceneBlackFix.m
//  见 WCSceneBlackFix.h 的说明。本文件不依赖 Logos / CydiaSubstrate，只用 UIKit + objc runtime，
//  可以直接放进任何 Theos tweak 工程（Makefile 里把 .m 加进 xxx_FILES 即可）。
//

#import "WCSceneBlackFix.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>
#import <sys/time.h>

// ============================================================
//  日志
// ------------------------------------------------------------
// 纯净版（编译期 -DWCF_NO_LOG=1 或 -DWCVK_NO_LOG=1）整体剥掉：
// 不只是不输出，连 [[NSString alloc] initWithFormat:] 的格式化和字符串常量都不生成。
// 这一点很重要 —— 之前 wcvoicekeep 的 pure 版其实一行都没剥，两个 dylib 代码完全一样。
// ============================================================
static void (^gWCFLogHandler)(NSString *) = nil;

#ifndef WCF_NO_LOG
#ifdef WCVK_NO_LOG
#define WCF_NO_LOG WCVK_NO_LOG
#else
#define WCF_NO_LOG 0
#endif
#endif

#if WCF_NO_LOG

#define WCFLog(...) do {} while (0)

#else

/// 日志专用串行队列：所有回调（写文件 / CFPreferences / NSLog）一律离开主线程执行。
/// 串行保证日志顺序与产生顺序一致；主线程这边只留一次很轻的字符串格式化。
static dispatch_queue_t WCFLogQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcvoicekeep.sceneblackfix.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void WCFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    void (^h)(NSString *) = gWCFLogHandler;
    // 调用方（比如写盘日志）抛异常绝不能顺着我们的调用栈往上炸，
    // 我们的日志点位于 willConnect / didBecomeActive 这类主线程关键路径上。
    dispatch_async(WCFLogQueue(), ^{
        @autoreleasepool {
            @try {
                if (h) h(s);
                else NSLog(@"[SceneBlackFix] %@", s);
            } @catch (NSException *e) {
                NSLog(@"[SceneBlackFix] 日志回调异常(%@)，原日志: %@", e.reason, s);
            }
        }
    });
}

#endif

void WCSceneBlackFixSetLog(void (^handler)(NSString *line)) {
    gWCFLogHandler = [handler copy];
}

static BOOL gWCFRewriteConfig = YES;
void WCSceneBlackFixSetRewriteConfig(BOOL on) { gWCFRewriteConfig = on; }

static BOOL gWCFInstalled = NO;

// 搬家前主窗口所在的 scene，兜底路径失败时回滚用。
// 必须是 __weak：以前是强引用，若「搬家成功但复查窗口没走到」（进程被挂起、检查被节流吞掉），
// 这个强引用会一直攥着一个已经销毁的 UIScene，拖住它的内存。
static __weak UIWindowScene *gWCFSavedMainScene = nil;

// 搬家前主窗口自身的 hidden / alpha，回滚时一并还原 ——
// 强制 hidden=NO alpha=1 是我们为了让窗口上屏做的，回滚就要还回去，
// 不能把 App 自己的隐藏状态永久改掉。
static BOOL    gWCFSavedHidden = NO;
static CGFloat gWCFSavedAlpha  = 1.0;

// 重入闸门：给 windowScene 赋值时 UIKit 可能同步回调 scene 相关方法，
// 万一绕回 willConnect，没有闸门就会「搬家 → 回调 → 再搬家」递归。
static BOOL gWCFInMove = NO;

// 主窗口：一次精准捕获，之后全程只读缓存，零查找。
// 以前的实现每调一次 WCFMainWindow 就遍历 app.windows + 多次 NSStringFromClass，
// 而 willConnect / 兜底检查一个进程里会调好几次，纯属白烧 CPU。
// 现在改成事件驱动：UIWindowDidBecomeVisibleNotification 里用强特征锁定，
// 命中即注销观察者，此后连通知都不再收到。
static __weak UIWindow *gWCFCachedMain = nil;
static BOOL gWCFMainLocked = NO;          // 强特征已锁定（不再接受弱候选覆盖）
static id   gWCFWindowObserver = nil;     // 一次性观察者 token

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

/// 基础门槛：是个能真正铺满屏幕的主界面窗口，不是 HUD / 键盘 / 弹窗。
static BOOL WCFLooksLikeMainWindow(UIWindow *w) {
    if (![w isKindOfClass:[UIWindow class]]) return NO;
    if (!w.rootViewController) return NO;
    if (w.windowLevel != UIWindowLevelNormal) return NO;
    CGSize b = w.bounds.size;
    CGSize s = [UIScreen mainScreen].bounds.size;
    return (b.width >= s.width * 0.5 && b.height >= s.height * 0.5);
}

/// 强特征：rootVC 名字直接说明这是主界面（微信是 MainTabBarViewController）。
/// 命中就永久锁定，不再让其它窗口覆盖，也不用再观察通知。
static BOOL WCFIsStrongMainWindow(UIWindow *w) {
    UIViewController *vc = w.rootViewController;
    if (!vc) return NO;
    NSString *rc = NSStringFromClass([vc class]);
    return [rc rangeOfString:@"MainFrame" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [rc rangeOfString:@"TabBar"    options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [rc rangeOfString:@"Console"   options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [rc rangeOfString:@"Main"      options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/// 捕获候选窗口。强特征命中即锁定 + 注销一次性观察者（之后零通知、零查找）。
static void WCFCaptureWindow(UIWindow *w) {
    if (!w || !WCFLooksLikeMainWindow(w)) return;
    // 缓存还在就别让别的窗口覆盖；缓存已被销毁（主窗口重建）时允许重新锁定。
    if (gWCFMainLocked && gWCFCachedMain) return;
    BOOL strong = WCFIsStrongMainWindow(w);
    gWCFCachedMain = w;
    if (!strong) return;                     // 弱候选先记着，等强特征出现

    gWCFMainLocked = YES;
    if (gWCFWindowObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:gWCFWindowObserver];
        gWCFWindowObserver = nil;
    }
    WCFLog(@"主窗口已精准锁定: %@ / rootVC=%@（后续零查找、零通知）",
           NSStringFromClass([w class]), NSStringFromClass([w.rootViewController class]));
}

/// 取主窗口。**快路径只有一次弱引用读取**，不做任何遍历、不造任何字符串。
/// 只有缓存还没建立时才走一次 O(1) 的 delegate.window / keyWindow 直取。
/// 注意：只允许主线程调用（UIKit 约束），本模块所有调用点都在主线程。
static UIWindow *WCFMainWindow(void) {
    UIWindow *cached = gWCFCachedMain;
    if (cached && cached.rootViewController) return cached;

    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *w = nil;
    @try {
        id d = app.delegate;
        if ([d respondsToSelector:@selector(window)]) w = [d window];
    } @catch (NSException *e) {}
    if (!w) { @try { w = app.keyWindow; } @catch (NSException *e) {} }

    if (w) WCFCaptureWindow(w);
    if (gWCFCachedMain) return gWCFCachedMain;

    // 只在「缓存还没建立」时走的最后一环：后台无头拉起时主窗口可能是 hidden，
    // 不会发 UIWindowDidBecomeVisibleNotification，delegate.window / keyWindow
    // 也可能都取不到。补一次 O(n) 遍历（微信通常只有 1~2 个窗口），命中即刻缓存，
    // 之后仍走上面的零遍历快路径 —— 保住 v2.0.29「一定能找到主窗口」的行为。
    @try {
        UIWindow *fallback = nil;
        CGFloat bestArea = 0;
        for (UIWindow *cand in app.windows) {
            if (!WCFLooksLikeMainWindow(cand)) continue;
            if (WCFIsStrongMainWindow(cand)) { WCFCaptureWindow(cand); return gWCFCachedMain; }
            CGFloat area = cand.bounds.size.width * cand.bounds.size.height;
            if (area > bestArea) { bestArea = area; fallback = cand; }
        }
        if (fallback) WCFCaptureWindow(fallback);
    } @catch (NSException *e) {}
    return gWCFCachedMain;
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

/// 系统类前缀过滤，纯 C 字符串比较（全类扫描时每类都会走一次，不能有对象分配）
static BOOL WCFNameHasSkipPrefix(const char *n) {
    static const char *kSkip[] = {
        "UI", "_UI", "NS", "_NS", "CA", "_CA", "Swift",
        "Foundation", "CoreFoundation", "CF", "_CF", "OS_", "WK", "SK", "AV", NULL
    };
    for (int i = 0; kSkip[i]; i++) {
        size_t len = strlen(kSkip[i]);
        if (strncmp(n, kSkip[i], len) == 0) return YES;
    }
    return NO;
}

// ============================================================
//  核心：把主窗口搬到指定 scene（纯窗口层操作）
// ============================================================
static BOOL WCFMoveMainWindowToScene(UIWindow *main, UIWindowScene *target, BOOL saveForRollback) {
    if (!main || !target) return NO;
    UIWindowScene *from = main.windowScene;
    if (from == target) return NO;
    if (gWCFInMove) { WCFLog(@"搬家: 重入保护，跳过（上一次搬家还没结束）"); return NO; }

    gWCFInMove = YES;
    @try {
        WCFLog(@"搬家: 主窗口 %p 从 scene %p(state=%ld) -> 目标 scene %p(state=%ld)",
               (__bridge void *)main,
               (__bridge void *)from, from ? (long)from.activationState : (long)-1,
               (__bridge void *)target, (long)target.activationState);

        // 记下原始状态，回滚时还原（别把 App 自己的 hidden/alpha 永久改掉）
        gWCFSavedHidden = main.isHidden;
        gWCFSavedAlpha  = main.alpha;
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

            // 主窗口 layoutIfNeeded 是必须的（落地首帧）。
            // vc.view.frame 对齐 + setNeedsDisplay 是 v2.0.29 就有的「上屏重绘」触发，
            // 必须原样保留（少了会亮屏但内容不刷新）；只把最贵的「整棵视图树
            // layoutIfNeeded」改成尺寸真的不一致时才做，省掉无谓的重排。
            BOOL needResize = vc.view &&
                !CGSizeEqualToSize(vc.view.frame.size, main.bounds.size);
            [main setNeedsLayout];
            [main layoutIfNeeded];
            if (vc.view) {
                vc.view.frame = main.bounds;
                [vc.view setNeedsDisplay];
                if (needResize) {
                    [vc.view setNeedsLayout];
                    [vc.view layoutIfNeeded];
                }
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
    } @finally {
        gWCFInMove = NO;
    }
}

static void WCFRollbackMainScene(UIWindow *main) {
    if (!main || !gWCFSavedMainScene) return;
    WCFLog(@"搬家后仍黑，回滚主窗口到原 scene %p", (__bridge void *)gWCFSavedMainScene);
    BOOL prevInMove = gWCFInMove;   // 保存/恢复闸门，别把外层搬家的状态踩掉
    gWCFInMove = YES;
    @try {
        main.windowScene = gWCFSavedMainScene;
        // 把搬家时强改的 hidden/alpha 还回去
        main.hidden = gWCFSavedHidden;
        main.alpha  = gWCFSavedAlpha;
        // 回滚是失败路径，不做同步全树 layout，交给下一个 runloop
        [main setNeedsLayout];
    } @catch (NSException *e) {
        WCFLog(@"回滚异常: %@", e.reason);
    } @finally {
        // 无论成功/异常都要放闸门，否则一次异常就会让后续搬家永远被重入保护挡掉
        gWCFSavedMainScene = nil;
        gWCFInMove = prevInMove;
    }
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
                    // 用 class_getName 的 C 字符串比较，不走 NSStringFromClass：
                    // 全类几万个，每类造一个 NSString 再 hasPrefix 会白烧几十 ms 和一堆临时对象，
                    // 而这段代码是在 ctor 里、主线程启动路径上。
                    const char *cn = class_getName(c);
                    if (!cn || !cn[0]) continue;
                    if (WCFNameHasSkipPrefix(cn)) continue;
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
        // self/_cmd/scene/session/options = 5 个参数。个数不对说明不是我们以为的那个方法，
        // 强行接管会拿到语义完全不同的参数（v2.0.22 的崩法就是这么来的）。
        if (method_getNumberOfArguments(m) != 5) {
            WCFLog(@"willConnect: %@ 参数个数=%u 不是 5，跳过",
                   NSStringFromClass(owner), method_getNumberOfArguments(m));
            continue;
        }
        IMP cur = method_getImplementation(m);
        if (cur == (IMP)WCFWillConnectHook) return;   // 已装过
        if (!cur) { WCFLog(@"willConnect: %@ 原实现为空，放弃接管", NSStringFromClass(owner)); continue; }
        IMP orig = method_setImplementation(m, (IMP)WCFWillConnectHook);
        if (!orig) {
            // 装上了却拿不到 orig，立刻还原，绝不留下一个「不调原实现」的 hook
            method_setImplementation(m, cur);
            WCFLog(@"willConnect: %@ 取 orig 失败，已还原", NSStringFromClass(owner));
            continue;
        }
        gWCFOrigWillConnect = orig;
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
    if (method_getNumberOfArguments(m) != 5) {
        WCFLog(@"scene-config: 参数个数=%u 不是 5，放弃以免崩", method_getNumberOfArguments(m));
        return;
    }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)WCFConfigForConnecting) return;
    if (!cur) { WCFLog(@"scene-config: 原实现为空，放弃接管"); return; }
    IMP orig = method_setImplementation(m, (IMP)WCFConfigForConnecting);
    if (!orig) {
        method_setImplementation(m, cur);   // 同上，拿不到 orig 就还原
        WCFLog(@"scene-config: 取 orig 失败，已还原");
        return;
    }
    gWCFOrigConfigForConnecting = orig;
    WCFLog(@"scene-config: 已接管 %@ 的 scene 配置方法", NSStringFromClass(owner));
}

// ============================================================
//  ③ 兜底：didBecomeActive 后 0.4s 结构检查
// ============================================================
static double const kWCFCheckDelay     = 0.4;    // 首次前台激活后多久检查
static double const kWCFVerifyDelay    = 0.35;   // 搬完多久复查
static double const kWCFCheckThrottle  = 1.0;    // 两次检查之间的最小间隔（防叠加）
static double const kWCFMainRetryDelay = 0.25;   // 主窗口还没建好时的重试间隔
static int    const kWCFMaxFix         = 6;      // 同一进程最多修几次（用户反复点开每次都要能修）
static int    const kWCFMainRetryMax   = 3;      // 慢启动时最多等主窗口 3 次

static int    gWCFFixCount      = 0;
static int    gWCFMainRetry     = 0;
static BOOL   gWCFWasHeadless   = NO;    // 本次进程是「后台无头拉起」的
static BOOL   gWCFCheckedOnce   = NO;    // 已经做过第一次检查
static BOOL   gWCFVerifyPending = NO;    // 上一次搬家的复查还没落地，别叠加第二次
static double gWCFLastCheckAt   = 0;     // 上次检查时间（节流）

static void WCFCheck(void) {
    gWCFCheckedOnce = YES;

    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *main = WCFMainWindow();
    if (!main) {
        // 慢启动时 0.4s 那一瞬间主窗口可能还没建好。以前直接「跳过，不动」，
        // 而 didBecomeActive 不会再来了 → 这一轮彻底漏修。改成短重试，且重试
        // 只做一次弱引用读取，不遍历窗口。
        if (gWCFMainRetry < kWCFMainRetryMax) {
            gWCFMainRetry++;
            WCFLog(@"兜底检查: 主窗口还没建好，%.2fs 后重试（%d/%d）",
                   kWCFMainRetryDelay, gWCFMainRetry, kWCFMainRetryMax);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWCFMainRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WCFCheck(); });
        } else {
            WCFLog(@"兜底检查: 重试 %d 次仍没有主窗口，放弃本轮（不遍历窗口）", kWCFMainRetryMax);
        }
        return;
    }
    gWCFMainRetry = 0;
    UIWindowScene *front = WCFActiveScene();
    NSUInteger frontUsable = WCFUsableWindowCount(front);
    BOOL onStage = WCFSceneOnStage(main);

    WCFLog(@"兜底检查: mainWindow=%@ onStage=%d 前台scene=%p(state=%ld) 前台可用窗口=%lu 全部窗口=%lu headless=%d",
           NSStringFromClass([main class]), onStage ? 1 : 0,
           (__bridge void *)front, front ? (long)front.activationState : (long)-1,
           (unsigned long)frontUsable,
           (unsigned long)app.windows.count, gWCFWasHeadless ? 1 : 0);

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
    if (gWCFVerifyPending) {
        WCFLog(@"兜底检查: 上次搬家的复查还没落地，跳过本轮（防止叠加搬家 + 叠加回滚）");
        return;
    }
    gWCFFixCount++;

    WCFLog(@"兜底检查: 命中黑屏（前台空场景）-> 第 %d 次搬家", gWCFFixCount);
    if (!WCFMoveMainWindowToScene(main, front, YES)) {
        WCFLog(@"兜底检查: 搬家失败");
        return;
    }
    gWCFVerifyPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWCFVerifyDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gWCFVerifyPending = NO;
        UIWindow *mw = WCFMainWindow();
        if (WCFHealthy(mw)) {
            gWCFSavedMainScene = nil;   // 成功就别再强持旧 scene 了
            WCFLog(@"兜底搬家成功：%.2fs 内界面恢复", kWCFVerifyDelay);
            return;
        }
        WCFRollbackMainScene(mw);
        WCFLog(@"兜底搬家后仍未恢复，已回滚");
    });
}

static void WCFOnDidBecomeActive(void) {
    // 节流：短时间内连续 didBecomeActive（微信切前后台很频繁）不叠加检查
    struct timeval tv; gettimeofday(&tv, NULL);
    double now = tv.tv_sec + tv.tv_usec / 1e6;
    if (gWCFLastCheckAt > 0 && now - gWCFLastCheckAt < kWCFCheckThrottle) return;
    gWCFLastCheckAt = now;

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

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // 一次性主窗口捕获：窗口 becomeVisible 时用强特征锁定，命中即注销观察者。
    // 这样「找主窗口」这件事总共只发生一次，之后不再收任何窗口通知。
    gWCFWindowObserver = [nc addObserverForName:UIWindowDidBecomeVisibleNotification
                                         object:nil queue:[NSOperationQueue mainQueue]
                                     usingBlock:^(NSNotification *note) {
        id obj = note.object;
        if ([obj isKindOfClass:[UIWindow class]]) WCFCaptureWindow((UIWindow *)obj);
    }];

    // 兼容「Install 晚于 didFinishLaunching」的接入方式（比如从别的 hook 里懒安装）：
    // 先按当前状态兜一次底，随后 didFinishLaunching 通知仍会覆盖成更准的值。
    @try {
        UIApplication *app0 = [UIApplication sharedApplication];
        gWCFWasHeadless = (app0 && app0.applicationState == UIApplicationStateBackground);
    } @catch (NSException *e) {}

    // 记录本进程是不是「后台无头拉起」。只有这种进程才会出现黑屏；
    // 用户自己点图标冷启动的进程只需要第一次确认，之后不必再扫。
    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        gWCFWasHeadless = ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground);
        WCFLog(@"didFinishLaunching: %@",
               gWCFWasHeadless ? @"后台无头拉起（会检查并修复）" : @"正常启动（只做首次确认）");
    }];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        // 非 headless 进程不会黑屏，做完第一次确认就不再介入
        if (!gWCFWasHeadless && gWCFCheckedOnce) return;
        WCFOnDidBecomeActive();   // ③ 兜底
    }];

    WCFLog(@"已安装（willConnect 抢先搬家 + 0.4s 兜底）");
}
