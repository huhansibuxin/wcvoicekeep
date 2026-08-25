// wcvoicekeep — 微信输入法语音免跳转 tweak (注入 com.tencent.wetype 主 App)
//
// ===== 铁律：日志必须写在 App 沙盒容器内 =====
// 用户 App 插件(dylib/deb)在沙盒内运行，/var/mobile/ 等沙盒外路径无写权限，
// 写外面会静默失败 -> 日志永远为空 -> 误判「没加载」。一律用 NSHomeDirectory()/Documents。
//
// 触发（与委托类名无关，避免 %hook AppDelegate 空挂）：
//   A. UIApplicationDidBecomeActiveNotification -> 自动建 PiP standby
//   B. UIApplicationDidFinishLaunchingNotification -> 启动兜底
//   C. 收 daemon 的 Darwin 通知 com.wcvoicekeep.pip.trigger -> 注销/respring 后兜底
//
// 探针：记录 bundleId、home、实际委托类、目标类/方法是否存在、是否真变成 active。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

static NSString *gLogPath = nil;
static const char *const kTriggerName = "com.wcvoicekeep.pip.trigger";

// v1.9.21：其他 App 音频在播（微信视频 PiP）——此时重建 wetype PiP 会抢唯一通道、
// 顶掉微信视频 PiP（老板实测：微信 pip 被回调关闭 + 恶性循环）。有音频绝不重建，
// 等视频结束（无音频）再建。AudioSessionGetProperty 已 deprecated，手写声明防 -Werror；
// .xm 按 ObjC++ 编译，C 符号必须 extern "C"。
extern "C" int AudioSessionGetProperty(unsigned int inID, unsigned int *ioDataSize, void *outData);
static BOOL OtherAudioPlaying(void) {
    unsigned int playing = 0;
    unsigned int sz = sizeof(playing);
    int st = AudioSessionGetProperty('othr', &sz, &playing);
    return (st == 0) && (playing != 0);
}

// 抗双注入 / 抗重复触发：
//   1) gRegistered —— 构造器若被两个 dylib 各跑一次，只注册一次通知，避免事件被触发 N 遍（日志打 24 遍的根因）
//   2) gLastEngage —— 同一进程内短间隔不要反复 setup/start 同一个 PiP 单例，避免状态互相踩导致崩
static BOOL gRegistered = NO;
static NSTimeInterval gLastEngage = 0;

static void InitLogPath(void) {
    if (gLogPath) return;
    NSArray<NSString *> *cands = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"],
        @"/var/mobile",
        @"/tmp",
    ];
    for (NSString *dir in cands) {
        NSString *p = [dir stringByAppendingPathComponent:@"wcvoicekeep.log"];
        FILE *f = fopen([p UTF8String], "a");
        if (f) { fclose(f); gLogPath = p; break; }
    }
    if (!gLogPath) gLogPath = @"/var/mobile/wcvoicekeep.log"; // 兜底（多半写不进）
}

static void WLog(NSString *fmt, ...) {
    InitLogPath();
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    // v1.9.23：日志上限 3M——超过则清空（防无限增长撑爆沙盒）
    @autoreleasepool {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:gLogPath error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] > 3ull * 1024 * 1024) {
            [[NSData data] writeToFile:gLogPath atomically:YES]; // 清空
        }
    }
    FILE *f = fopen([gLogPath UTF8String], "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
    NSLog(@"[WCVK] %@", msg); // 双保险，syslog 也能看到
}

// ===== v1.9.0 预热模式：前台拉起 → 建 PiP → 自动退后台（PiP 自保活，0 CPU）=====
// 后台起 PiP 被系统硬限制（UIScene 必须 ForegroundActive，AVKit 错误 -1001 铁证），
// 音频保活又耗 media 服务（老板否决）。最终架构（老板拍板）：
//   daemon 开机后前台拉起 wetype 一次（闪 ~0.5s，带 --wcvk-warmup 参数）
//   -> App 激活，dylib 立即建 PiP（isActive=1）
//   -> 判定是预热 -> [[UIApplication suspend]] 自动退后台
//   -> PiP 常驻后台 = 自保活凭证（无媒体服务、不耗 CPU），点语音按钮不跳转
static BOOL gWarmupArg = NO;
static NSTimeInterval gLaunchTime = 0;
// 预热判定：daemon 带 --wcvk-warmup 参数（首选），或启动后 8s 内的前台激活（无参兜底，
// daemon 的 SBSLaunchApplicationForDebugging 不可用时的 fallback 拉起场景）。
static BOOL IsWarmup(void) {
    if (gWarmupArg) return YES;
    return ([[NSDate date] timeIntervalSince1970] - gLaunchTime) < 8.0;
}
// 自动退后台（模拟按 Home 键，PiP 会继续显示并保活；已在后台则跳过）
static void AutoBackground(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if ([app applicationState] == UIApplicationStateBackground) return; // 已在后台
    if ([app respondsToSelector:@selector(suspend)]) {
        WLog(@"WARMUP PiP active -> calling [UIApplication suspend] (auto-background)");
        [app performSelector:@selector(suspend)];
    } else {
        WLog(@"WARMUP no -suspend selector on UIApplication?!");
    }
}

// v1.9.14：pip.built 上报与自动退后台解耦——PiP 一建好（isActive=1）就上报 daemon
//（gPipUp=YES，daemon 才能走 SUSPENDED 检测/正常看护），只有预热场景才自动退后台。
// 修复 v1.9.13 实测 bug：SBSLaunchApplicationForDebugging 带参拉起失败(7) fallback 无参拉起
// 导致 gWarmupArg=NO + PiP 慢启动 8s 才建好（超 8s 预热窗口）-> IsWarmup()=NO
// -> WarmupDone 不执行 -> pip.built 永远不发 -> daemon gPipUp 永 NO -> 僵尸死循环。
static void WarmupDone(void) {
    uint32_t st = notify_post("com.wcvoicekeep.pip.built");
    WLog(@"WARMUP posted com.wcvoicekeep.pip.built -> %u (0=ok)", st);
    if (IsWarmup()) AutoBackground(); // 仅预热才自动退后台（手动打开不打扰）
}

// ===== v1.9.20：PiP 丢失秒级重建（换方案：KVO 私有类不兼容已证伪）=====
// 实测 v1.9.19：KVO registered 成功但 WBVoiceInputPIPManager.isActive 是手动 getter
// 不触发回调（PIPLOST 永远不打）-> 换组合方案：
//   主：swizzle AVPictureInPictureController.isPictureInPictureActive getter——
//       wetype 内部每次读 PiP 状态都经过它，翻转 1->0 瞬间发 pip.lost（事件驱动零轮询）
//   兜底：10s 低频纯内存守护（objc_msgSend 微秒级，不写盘不跨进程，非心跳）——
//       防 AVKit 内部不读 getter 的漏网
// daemon 收到 pip.lost -> 立即回发 pip.trigger -> dylib 在 scene active 下后台重建（无跳转）
// v1.9.25：守护按需启动（前向声明，定义在下方）
static void ReportPiPLost(void);
static void StartPiPGuard(void);
static void EnsureStandbyPiP(void); // v1.9.31：guard 本地直接 rebuild（定义在 368 行）
static void StopPiPGuard(void);
@interface WCVKPiPWatcher : NSObject
@end
static WCVKPiPWatcher *gPiPWatcher = nil;
@implementation WCVKPiPWatcher
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSNumber *nv = change[NSKeyValueChangeNewKey];
    if (![nv respondsToSelector:@selector(boolValue)]) return;
    if (![nv boolValue]) {
        WLog(@"PIPLOST KVO(pipController) isActive->NO -> notify daemon");
        ReportPiPLost();
        StartPiPGuard(); // v1.9.25：按需守护
    }
}
@end

static void ReportPiPLost(void) {
    WLog(@"PIPLOST detected -> notify daemon (immediate rebuild)");
    notify_post("com.wcvoicekeep.pip.lost");
}

// 主：swizzle AVKit getter（事件驱动零轮询）。
// v1.9.21：翻转状态 last 用关联对象按 controller 隔离（防同进程多 controller 互扰）。
static void SwizzleAVPiPActive(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("AVPictureInPictureController");
        if (!cls) { WLog(@"PIPWATCH AVPictureInPictureController class nil"); return; }
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"isPictureInPictureActive"));
        if (!m) { WLog(@"PIPWATCH no isPictureInPictureActive method"); return; }
        IMP orig = method_getImplementation(m);
        static char kLastKey;
        IMP newImp = imp_implementationWithBlock(^(id self) {
            BOOL v = ((BOOL (*)(id, SEL))orig)(self, NSSelectorFromString(@"isPictureInPictureActive"));
            NSNumber *lastN = objc_getAssociatedObject(self, &kLastKey);
            BOOL last = lastN ? [lastN boolValue] : NO;
            if (v != last) {
                objc_setAssociatedObject(self, &kLastKey, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!v) { // 1->0：PiP 被顶掉 -> 立即上报 + 按需守护
                    ReportPiPLost();
                    StartPiPGuard();
                }
            }
            return v;
        });
        method_setImplementation(m, newImp);
        WLog(@"PIPWATCH swizzled AVPictureInPictureController.isPictureInPictureActive (v1.9.21)");
    });
}

// 兜底：按需守护（v1.9.25，替代常驻 2s）——平时零定时器零查询，
// 只有 swizzle/KVO 检测到 PiP 掉（1->0）才启动 2s 守护做重建重试，PiP 回来即停。
// 音频门控保持：PiP 没活着 且 无其他音频 才重发 pip.lost（微信视频 PiP 在播不抢）。
static time_t gLastLost = 0;
static dispatch_source_t gGuardTimer = nil;
static BOOL gGuardRunning = NO;
static void StopPiPGuard(void) {
    if (gGuardRunning && gGuardTimer) {
        dispatch_source_cancel(gGuardTimer);
        gGuardTimer = nil;
        gGuardRunning = NO;
        WLog(@"PIPWATCH guard stopped (PiP back, zero-timer again)");
    }
}
static void StartPiPGuard(void) {
    if (gGuardRunning) return;
    gGuardTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(gGuardTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gGuardTimer, ^{
        @autoreleasepool {
            Class mc = objc_getClass("WBVoiceInputPIPManager");
            id m = mc ? ((id (*)(Class, SEL))objc_msgSend)(mc, NSSelectorFromString(@"sharedInstance")) : nil;
            BOOL act = m ? ((BOOL (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"isActive")) : NO;
            if (act) {
                // v1.9.30 实验结论（16:10 实测）：系统自动恢复不存在（15s 窗口 FAILED），
                // PiP 回来只可能来自我们自己的 rebuild。这里打日志后停守护。
                WLog(@"GUARD PiP back (isActive=YES) -> stop guard");
                StopPiPGuard(); return;
            }
            // v1.9.31：系统自动恢复已证伪（v1.9.30 实验 15s FAILED），不再等——
            // 音频 idle（视频结束）后立即 rebuild，节流 2s（原 5s，恢复窗口更短；
            // EnsureStandbyPiP 内部还有 2s cooldown 双保险，不会反复刷）。
            // v1.9.31 加速：本地主线程直接 rebuild（跳过 daemon 通知往返），
            // 同时仍通知 daemon 更新 gPipUp 状态。
            if (!OtherAudioPlaying() && time(NULL) - gLastLost >= 2) {
                gLastLost = time(NULL);
                WLog(@"GUARD PiP down & audio idle -> local rebuild (v1.9.31)");
                dispatch_async(dispatch_get_main_queue(), ^{ EnsureStandbyPiP(); });
                ReportPiPLost(); // 通知 daemon：gPipUp=NO，等 pip.built
            }
        }
    });
    dispatch_resume(gGuardTimer);
    gGuardRunning = YES;
    WLog(@"PIPWATCH guard started (on-demand, PiP lost)");
}

// v1.9.29：hook UIScene.activationState——wetype 后台时伪装 ForegroundActive。
// 背景：SB 标记法漏拦独立路径 deactivationReasons -> scene 实际被系统 deactivate
// -> AVKit startPictureInPicture 进程内检查 UISceneActivationStateForegroundActive
// 不通过 -> 后台重建 PiP 永远失败（打断要跳转）。这里直接让 AVKit 检查放行。
// ⚠️ v1.9.28 崩溃根因：block 里调 [[UIApplication sharedApplication] applicationState]
// 造成递归（applicationState 内部读 scene activationState = 我们 hook 的方法 -> 栈溢出）。
// v1.9.29 修：block 内绝不调任何 UIKit API，只读静态标志 gWCVKAppActive
//（由 DidBecomeActive/DidEnterBackground 通知维护，见 CTOR）。
static BOOL gWCVKAppActive = NO; // 前台激活标志（通知维护，hook block 只读它）
static void SwizzleSceneActivationState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("UIScene");
        if (!cls) { WLog(@"SCENEHOOK UIScene class nil"); return; }
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"activationState"));
        if (!m) { WLog(@"SCENEHOOK no activationState method"); return; }
        IMP orig = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id self) {
            // 只读 static 标志 + 调原始实现——禁止任何 UIKit 调用（递归崩溃根因）
            NSInteger v = ((NSInteger (*)(id, SEL))orig)(self, NSSelectorFromString(@"activationState"));
            if (!gWCVKAppActive && v != UISceneActivationStateForegroundActive) {
                // 后台：伪装前台激活（UISceneActivationStateForegroundActive = 0）
                return (NSInteger)UISceneActivationStateForegroundActive;
            }
            return v;
        });
        method_setImplementation(m, newImp);
        WLog(@"SCENEHOOK swizzled UIScene.activationState (gWCVKAppActive flag, v1.9.29)");
    });
}

static void WatchPiPLost(id mgr) {
    SwizzleAVPiPActive(); // 主：swizzle AVKit getter（事件驱动，零定时器待命）
    SwizzleSceneActivationState(); // v1.9.28：后台伪装 scene 激活态，AVKit 检查放行
    // v1.9.25：守护按需启动——swizzle/KVO 检测到 PiP 掉才 StartPiPGuard，平时零定时器
    // 附：尝试 KVO pipController（AVKit 属性 KVO 兼容，能拿到就双保险）
    if (gPiPWatcher) return;
    @try {
        id pipCtl = [mgr valueForKey:@"pipController"];
        if (pipCtl) {
            gPiPWatcher = [WCVKPiPWatcher new];
            [pipCtl addObserver:gPiPWatcher forKeyPath:@"pictureInPictureActive"
                        options:NSKeyValueObservingOptionNew context:nil];
            WLog(@"PIPWATCH KVO pipController.pictureInPictureActive registered");
        }
    } @catch (NSException *e) {
        WLog(@"PIPWATCH KVO pipController failed: %@", e);
    }
}

// 探针：记录真实 UIApplication 委托类名，验证「AppDelegate 假设」对不对
static void ProbeDelegate(void) {
    UIApplication *app = [UIApplication sharedApplication];
    id del = app.delegate;
    WLog(@"PROBE real delegate class = %@  (binary 含 AppDelegate 字面量 ≠ 真委托)",
         del ? NSStringFromClass([del class]) : @"(nil)");
}

// 探测 WBVoiceStateProbe（扩展真正读的 standby 标志类）
static void ProbeStateProbe(void) {
    Class cls = objc_getClass("WBVoiceStateProbe");
    WLog(@"PROBE WBVoiceStateProbe class = %@", cls ?: @"(nil)");
    if (!cls) return;
    SEL s1 = NSSelectorFromString(@"pictureInPictureActive");
    SEL s2 = NSSelectorFromString(@"isMainAppVoiceStandbyActive");
    SEL s3 = NSSelectorFromString(@"setPictureInPictureActive:");
    SEL s4 = NSSelectorFromString(@"sharedInstance");
    SEL s5 = NSSelectorFromString(@"updateRecordingStandbyMode");
    WLog(@"PROBE WBVoiceStateProbe responds picActive=%d isMainAppStandby=%d setPicActive=%d shared=%d updateStandby=%d",
         (int)class_respondsToSelector(cls, s1),
         (int)class_respondsToSelector(cls, s2),
         (int)class_respondsToSelector(cls, s3),
         (int)class_respondsToSelector(cls, s4),
         (int)class_respondsToSelector(cls, s5));
    id inst = nil;
    if (class_respondsToSelector(cls, s4)) inst = ((id (*)(Class, SEL))objc_msgSend)(cls, s4);
    else { inst = ((id (*)(Class, SEL))objc_msgSend)(cls, NSSelectorFromString(@"new")); }
    if (inst) {
        if ([inst respondsToSelector:s2])
            WLog(@"PROBE WBVoiceStateProbe.isMainAppVoiceStandbyActive = %d",
                 (int)((BOOL (*)(id, SEL))objc_msgSend)(inst, s2));
        if ([inst respondsToSelector:s1])
            WLog(@"PROBE WBVoiceStateProbe.pictureInPictureActive = %d",
                 (int)((BOOL (*)(id, SEL))objc_msgSend)(inst, s1));
    }
}

// 真正启动 PiP standby 的正确顺序（来自本地 wxkb 二进制的 ObjC 元数据分析）：
//   开关 gate: WBVoiceInputManager.recordingStandbyMode 必须 =1
//             (+[WBVoiceInputPolicy shouldUsePIPStandbyMode] = recordingStandbyMode==1 && isPipSupported)
//   建 controller: WBVoiceInputPIPManager setup (建 pipController/pipSourceView/pipContentVC)
//   启 standby:    setStandbyPlaybackStateEnabled:1
//   预备:          preparePictureInPictureForStandby  (gate 过才不早退)
//   真正起 PiP:    startWithCompletionHandler:        (startPictureInPicture)
// 之前 v1.4~1.6 死在两点：(1) 开关在 Manager 不在 Policy，从未置 1；(2) 只 prepare 没 setup/start。
// 真正执行一次 engage（置开关 -> setup -> setStandby -> prepare -> start）。
// 不做幂等/冷却判断（由 EnsureStandbyPiP 外层负责），便于内部重试。
static void EngageOnce(id mgr, int attempt) {
    SEL isSupported = NSSelectorFromString(@"isSupported");
    SEL isSetup     = NSSelectorFromString(@"isSetup");
    SEL setup       = NSSelectorFromString(@"setup");
    SEL setStandby  = NSSelectorFromString(@"setStandbyPlaybackStateEnabled:");
    SEL startSel    = NSSelectorFromString(@"startWithCompletionHandler:");
    SEL standby     = NSSelectorFromString(@"preparePictureInPictureForStandby");
    SEL shared      = NSSelectorFromString(@"sharedInstance");

    BOOL vSetup = [mgr respondsToSelector:isSetup] ? ((BOOL (*)(id,SEL))objc_msgSend)(mgr, isSetup) : NO;
    WLog(@"PROBE [attempt %d] isSupported=%d isSetup=%d", attempt,
         (int)([mgr respondsToSelector:isSupported] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,isSupported):NO),
         (int)vSetup);

    // (1) 开门控 recordingStandbyMode=1（WBVoiceInputManager 上，非 Policy）
    Class vmCls = objc_getClass("WBVoiceInputManager");
    if (vmCls && [vmCls respondsToSelector:shared]) {
        id vm = ((id (*)(Class, SEL))objc_msgSend)(vmCls, shared);
        SEL setMode = NSSelectorFromString(@"setRecordingStandbyMode:");
        SEL updMode = NSSelectorFromString(@"updateRecordingStandbyMode:");
        if (vm) {
            if (setMode && [vm respondsToSelector:setMode]) ((void(*)(id,SEL,NSInteger))objc_msgSend)(vm,setMode,1);
            if (updMode && [vm respondsToSelector:updMode]) ((void(*)(id,SEL,NSInteger))objc_msgSend)(vm,updMode,1);
        }
    } else {
        WLog(@"PROBE WBVoiceInputManager NOT found (无法置 recordingStandbyMode)");
    }

    // (2) setup：建 pipController / pipSourceView / pipContentVC（仅首次 isSetup=0）
    if (!vSetup && [mgr respondsToSelector:setup]) { WLog(@"PROBE calling setup"); ((void(*)(id,SEL))objc_msgSend)(mgr,setup); }
    // (3) 启 standby 播放状态
    if ([mgr respondsToSelector:setStandby]) ((void(*)(id,SEL,BOOL))objc_msgSend)(mgr,setStandby,YES);
    // (4) prepare standby（gate 过才生效）
    if (![mgr respondsToSelector:standby]) { WLog(@"PROBE no -preparePictureInPictureForStandby"); return; }
    ((void(*)(id,SEL))objc_msgSend)(mgr,standby);
    WLog(@"PROBE preparePictureInPictureForStandby INVOKED");

    // (4.5) v1.9.31 加速：先试 resume 快速路径——PiP 被顶 = suspended 而非销毁，
    // AVPictureInPictureController resumePictureInPicture（iOS 15+ 公开 API）应远快于
    // 重新 start（start 冷启动 ~4s）。resume 后 0.6s 确认 isActive，生效则跳过 start。
    SEL iaSel = NSSelectorFromString(@"isActive");
    @try {
        id pipCtl = [mgr valueForKey:@"pipController"];
        if (pipCtl && [pipCtl respondsToSelector:NSSelectorFromString(@"resumePictureInPicture")]) {
            WLog(@"PROBE resumePictureInPicture (fast path) attempt");
            ((void(*)(id,SEL))objc_msgSend)(pipCtl, NSSelectorFromString(@"resumePictureInPicture"));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                BOOL act = [mgr respondsToSelector:iaSel] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,iaSel) : NO;
                WLog(@"PROBE after resume 0.6s isActive=%d", (int)act);
                if (act) { WarmupDone(); return; } // resume 生效：上报（不退后台，rebuild 场景）
                WLog(@"PROBE resume not effective -> full start (fallback)");
                if ([mgr respondsToSelector:startSel]) {
                    void (^completion)(BOOL) = ^(BOOL ok) {
                        BOOL a2 = [mgr respondsToSelector:iaSel] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,iaSel) : NO;
                        WLog(@"PROBE startWithCompletionHandler fired ok=%d isActive=%d", (int)ok, (int)a2);
                        if (a2) WarmupDone();
                    };
                    ((void(*)(id,SEL,id))objc_msgSend)(mgr,startSel,completion);
                }
            });
            return; // resume 路径已接管，本函数结束（0.6s 后要么 resume 生效要么 full start）
        }
    } @catch (NSException *e) {
        WLog(@"PROBE resume failed: %@", e);
    }

    // (5) 真正 start PiP —— v1.9.2：传完成回调，PiP 一建好立刻报 daemon + 退后台（零轮询延迟）。
    // 安全：block 体忽略参数语义（不读入参，防 wetype 真实签名是 ^(void)/^(NSError*) 时崩），
    // 且回调内再核 isActive 实况 —— 若回调是"将要开始"而非"已完成"，isActive=0 则跳过，
    // 由下方轮询兜底，绝不提前退。
    if ([mgr respondsToSelector:startSel]) {
        WLog(@"PROBE calling startWithCompletionHandler:(completion)");
        void (^completion)(BOOL) = ^(BOOL ok) {
            BOOL act = [mgr respondsToSelector:iaSel] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,iaSel) : NO;
            WLog(@"PROBE startWithCompletionHandler fired ok=%d isActive=%d", (int)ok, (int)act);
            if (act) WarmupDone(); // v1.9.14：PiP 建好即上报（解耦，见 WarmupDone 注释）
        };
        ((void(*)(id,SEL,id))objc_msgSend)(mgr,startSel,completion);
    }
}

static void EnsureStandbyPiP(void) {
    Class mgrCls = objc_getClass("WBVoiceInputPIPManager");
    if (!mgrCls) { WLog(@"PROBE WBVoiceInputPIPManager NOT FOUND"); return; }
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (![mgrCls respondsToSelector:shared]) { WLog(@"PROBE no +sharedInstance"); return; }
    id mgr = ((id (*)(Class, SEL))objc_msgSend)(mgrCls, shared);
    if (!mgr) { WLog(@"PROBE sharedInstance nil"); return; }

    SEL isActive = NSSelectorFromString(@"isActive");
    BOOL vActive = [mgr respondsToSelector:isActive] ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isActive) : NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 幂等 + 抗抖动：已 active 跳过；<2s 重复触发跳过（防双 dylib 反复戳单例崩安全模式）
    if (vActive) { WLog(@"PROBE already active, skip"); return; }
    if (now - gLastEngage < 2.0) { WLog(@"PROBE cooldown skip (last engage %.1fs ago)", now - gLastEngage); return; }
    gLastEngage = now;

    WLog(@"PROBE WBVoiceInputPIPManager found");
    EngageOnce(mgr, 0);
    WatchPiPLost(mgr); // v1.9.19：PiP 丢失秒级重建（KVO 事件驱动）

    // v1.9.4 曾加 1.5s 强制定时退后台 —— 实测失败（01:17:12 日志：WillResignActive 时
    // isActive=0，PiP 未建好就被退，App 挂起被清无法保活）。v1.9.5 回退：
    // 等 PiP 确认（completion/轮询 isActive=1）再退后台 —— 闪屏时长 ≈ PiP 启动时间，压不掉。

    // 轮询 + 重试：冷态 startPictureInPicture 概率成功（即便留前台也偶发失败，见 10:34:42 段）。
    // 前台窗口内重 prepare+start 2 次（0.8s/1.6s）。一旦滑后台，重试也在后台必败 ——
    // 所以真正关键是首次 start 压到前台尽快执行（见 TriggerOnMain 0 延迟）。
    __block int attempt = 0;
    // v1.9.1：首次检测提前到 0.4s（原 0.8s），闪屏更短；起不来再 1.0/1.8 补刀
    for (NSNumber *secs in @[@(0.4), @(1.0), @(1.8)]) {
        double d = [secs doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL active = [mgr respondsToSelector:isActive] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,isActive) : NO;
            WLog(@"PROBE t=%.1fs isActive=%d", d, (int)active);
            if (active) {
                // v1.9.14：PiP 建好即上报（解耦），预热时才自动退后台
                WarmupDone();
                return;
            }
            if (attempt < 3) {
                attempt++;
                WLog(@"PROBE retry engage (attempt %d) — 冷态 start 偶发失败，重 prepare+start", attempt);
                EngageOnce(mgr, attempt);
            }
        });
    }
    // 尾部确认
    for (NSNumber *secs in @[@(2.5), @(4.0), @(8.0)]) {
        double d = [secs doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL active = [mgr respondsToSelector:isActive] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,isActive) : NO;
            WLog(@"PROBE t=%.1fs isActive=%d", d, (int)active);
            if (active) {
                WarmupDone();   // v1.9.14：兜底上报（解耦）
            } else if (IsWarmup() && d >= 4.0) {
                WLog(@"WARMUP PiP still not active at %.1fs -> background anyway (avoid stuck UI)", d);
                AutoBackground();   // 安全网：预热时绝不让 UI 一直占屏
            }
        });
    }
}

static void TriggerOnMain(void) {
    // 0 延迟：becomeActive 后下一个 run loop 立即执行，赶在用户滑后台挂起前把 PiP 拉起来。
    // dispatch 定时器与 dyld 完全无关（dylib 在进程启动最早阶段已由 dyld 加载完，远早于本通知），
    // 不存在抢锁风险；延迟越短，前台窗口越大，越不易被滑后台打断。
    dispatch_async(dispatch_get_main_queue(), ^{
        ProbeDelegate();
        // v1.9.28：去掉 applicationState 一刀切跳过——SB 标记法漏洞导致 scene 可能
        // 被系统部分 deactivate（applicationState=Background），PiP 丢失时也必须重建。
        // 配合 SwizzleSceneActivationState（后台伪装 ForegroundActive）+ 音频门控，
        // 后台重建 PiP 现在能成功；重复触发由 EnsureStandbyPiP 的 vActive/2s cooldown
        // 幂等把关，不会反复建。
        UIApplicationState st = [[UIApplication sharedApplication] applicationState];
        WLog(@"TRIGGER appState=%ld -> EnsureStandbyPiP (audio-gated, v1.9.28)", (long)st);
        EnsureStandbyPiP();
    });
}

__attribute__((constructor)) static void __wcVKInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        WLog(@"CTOR bundleId=%@ home=%@ logPath=%@", bid, NSHomeDirectory(), gLogPath);
        if (![bid isEqualToString:@"com.tencent.wetype"]) {
            WLog(@"CTOR not wetype, skip");
            return;
        }
        WLog(@"CTOR injected into WeChat Keyboard, registering triggers");

        // v1.9.0：记录启动时间 + 预热参数（daemon 带 --wcvk-warmup 前台拉起时）
        gLaunchTime = [[NSDate date] timeIntervalSince1970];
        for (NSString *a in [[NSProcessInfo processInfo] arguments]) {
            if ([a isEqualToString:@"--wcvk-warmup"]) gWarmupArg = YES;
        }
        WLog(@"WARMUP arg=%d launchTs=%.0f", (int)gWarmupArg, gLaunchTime);

        // 去重：若构造器被两个 dylib 各跑一次（旧版没删+新版同注），只注册一次，
        // 避免同一事件被触发 N 遍（日志打 24 遍、并反复戳 PiP 单例导致崩进安全模式）。
        if (gRegistered) { WLog(@"CTOR already registered (duplicate dylib load?) -> skip re-register"); return; }
        gRegistered = YES;

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            // v1.9.29：更新前台标志（SCENEHOOK 只读它，不调 UIKit 防递归崩溃）
            gWCVKAppActive = YES;
            WLog(@"EVT UIApplicationDidBecomeActive -> TriggerOnMain (appActive=YES)");
            TriggerOnMain();
        }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            // v1.9.29：退后台置 NO -> SCENEHOOK 开始伪装 ForegroundActive
            gWCVKAppActive = NO;
            WLog(@"EVT UIApplicationDidEnterBackground -> appActive=NO (SCENEHOOK fake active)");
        }];

        // 退后台前探针：确认 PiP 是否已在建。若退后台前 isActive=0，说明用户滑太快/没建起来
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            Class mc = objc_getClass("WBVoiceInputPIPManager");
            id m = mc ? ((id (*)(Class,SEL))objc_msgSend)(mc, NSSelectorFromString(@"sharedInstance")) : nil;
            BOOL a = m ? ((BOOL (*)(id,SEL))objc_msgSend)(m, NSSelectorFromString(@"isActive")) : NO;
            WLog(@"EVT UIApplicationWillResignActive -> PiP isActive before bg = %d  (0=来不及建，下次前台会重试)", (int)a);
        }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            WLog(@"EVT UIApplicationDidFinishLaunching -> TriggerOnMain");
            TriggerOnMain();
        }];

        int token = 0;
        notify_register_dispatch(kTriggerName, &token, dispatch_get_main_queue(), ^(int t) {
            // v1.9.21：后台 trigger 前查音频——微信视频 PiP 在播（有声音）时跳过重建，
            // 避免 wetype 抢通道顶掉微信视频 PiP。前台激活（DidBecomeActive）不受此限。
            if (OtherAudioPlaying()) {
                WLog(@"EVT darwin trigger but OTHER AUDIO playing (WeChat video PiP?) -> skip rebuild");
                return;
            }
            WLog(@"EVT darwin trigger -> TriggerOnMain");
            TriggerOnMain();
        });

        WLog(@"CTOR setup done");
    }
}
