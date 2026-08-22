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
    FILE *f = fopen([gLogPath UTF8String], "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
    NSLog(@"[WCVK] %@", msg); // 双保险，syslog 也能看到
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
    // (5) 真正 start PiP
    if ([mgr respondsToSelector:startSel]) { WLog(@"PROBE calling startWithCompletionHandler:"); ((void(*)(id,SEL,id))objc_msgSend)(mgr,startSel,NULL); }
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

    // 轮询 + 重试：冷态 startPictureInPicture 概率成功（即便留前台也偶发失败，见 10:34:42 段）。
    // 前台窗口内重 prepare+start 2 次（0.8s/1.6s）。一旦滑后台，重试也在后台必败 ——
    // 所以真正关键是首次 start 压到前台尽快执行（见 TriggerOnMain 0 延迟）。
    __block int attempt = 0;
    for (NSNumber *secs in @[@(0.8), @(1.6)]) {
        double d = [secs doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL active = [mgr respondsToSelector:isActive] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,isActive) : NO;
            WLog(@"PROBE t=%.1fs isActive=%d", d, (int)active);
            if (!active && attempt < 2) {
                attempt++;
                WLog(@"PROBE retry engage (attempt %d) — 冷态 start 偶发失败，重 prepare+start", attempt);
                EngageOnce(mgr, attempt);
            }
        });
    }
    // 尾部确认
    for (NSNumber *secs in @[@(2.0), @(4.0), @(8.0)]) {
        double d = [secs doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL active = [mgr respondsToSelector:isActive] ? ((BOOL(*)(id,SEL))objc_msgSend)(mgr,isActive) : NO;
            WLog(@"PROBE t=%.1fs isActive=%d", d, (int)active);
        });
    }
}

static void TriggerOnMain(void) {
    // 0 延迟：becomeActive 后下一个 run loop 立即执行，赶在用户滑后台挂起前把 PiP 拉起来。
    // dispatch 定时器与 dyld 完全无关（dylib 在进程启动最早阶段已由 dyld 加载完，远早于本通知），
    // 不存在抢锁风险；延迟越短，前台窗口越大，越不易被滑后台打断。
    dispatch_async(dispatch_get_main_queue(), ^{
        ProbeDelegate();
        WLog(@"TRIGGER firing EnsureStandbyPiP (0-delay)");
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

        // 去重：若构造器被两个 dylib 各跑一次（旧版没删+新版同注），只注册一次，
        // 避免同一事件被触发 N 遍（日志打 24 遍、并反复戳 PiP 单例导致崩进安全模式）。
        if (gRegistered) { WLog(@"CTOR already registered (duplicate dylib load?) -> skip re-register"); return; }
        gRegistered = YES;

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            WLog(@"EVT UIApplicationDidBecomeActive -> TriggerOnMain");
            TriggerOnMain();
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
            WLog(@"EVT darwin trigger -> TriggerOnMain");
            TriggerOnMain();
        });

        WLog(@"CTOR setup done");
    }
}
