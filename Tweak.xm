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
static void EnsureStandbyPiP(void) {
    Class mgrCls = objc_getClass("WBVoiceInputPIPManager");
    if (!mgrCls) { WLog(@"PROBE WBVoiceInputPIPManager NOT FOUND"); return; }
    WLog(@"PROBE WBVoiceInputPIPManager found");

    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (![mgrCls respondsToSelector:shared]) { WLog(@"PROBE no +sharedInstance"); return; }
    id mgr = ((id (*)(Class, SEL))objc_msgSend)(mgrCls, shared);
    if (!mgr) { WLog(@"PROBE sharedInstance nil"); return; }

    SEL isActive    = NSSelectorFromString(@"isActive");
    SEL isSupported = NSSelectorFromString(@"isSupported");
    SEL isSetup     = NSSelectorFromString(@"isSetup");
    SEL setup       = NSSelectorFromString(@"setup");
    SEL setStandby  = NSSelectorFromString(@"setStandbyPlaybackStateEnabled:");
    SEL startSel    = NSSelectorFromString(@"startWithCompletionHandler:");
    SEL standby     = NSSelectorFromString(@"preparePictureInPictureForStandby");

    BOOL vActive    = [mgr respondsToSelector:isActive]    ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isActive) : NO;
    BOOL vSupported = [mgr respondsToSelector:isSupported] ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isSupported) : NO;
    BOOL vSetup     = [mgr respondsToSelector:isSetup]     ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isSetup) : NO;
    WLog(@"PROBE mgr isActive=%d isSupported=%d isSetup=%d", (int)vActive, (int)vSupported, (int)vSetup);

    // (1) 打开 standby 模式开关 —— 在 WBVoiceInputManager 上（不是 Policy）
    Class vmCls = objc_getClass("WBVoiceInputManager");
    if (vmCls && [vmCls respondsToSelector:shared]) {
        id vm = ((id (*)(Class, SEL))objc_msgSend)(vmCls, shared);
        SEL setMode = NSSelectorFromString(@"setRecordingStandbyMode:");
        SEL updMode = NSSelectorFromString(@"updateRecordingStandbyMode:");
        SEL getMode = NSSelectorFromString(@"recordingStandbyMode");
        if (vm) {
            if (getMode && [vm respondsToSelector:getMode])
                WLog(@"PROBE VoiceInputManager.recordingStandbyMode(before)=%ld",
                     (long)((NSInteger (*)(id,SEL))objc_msgSend)(vm, getMode));
            if (setMode && [vm respondsToSelector:setMode])
                ((void (*)(id,SEL,NSInteger))objc_msgSend)(vm, setMode, 1);
            if (updMode && [vm respondsToSelector:updMode])
                ((void (*)(id,SEL,NSInteger))objc_msgSend)(vm, updMode, 1);
            if (getMode && [vm respondsToSelector:getMode])
                WLog(@"PROBE VoiceInputManager.recordingStandbyMode(after)=%ld",
                     (long)((NSInteger (*)(id,SEL))objc_msgSend)(vm, getMode));
        }
    } else {
        WLog(@"PROBE WBVoiceInputManager NOT found (无法置 recordingStandbyMode)");
    }

    // (2) setup：建 pipController / pipSourceView / pipContentVC（若还没建）
    if (!vSetup && [mgr respondsToSelector:setup]) {
        WLog(@"PROBE calling setup");
        ((void (*)(id, SEL))objc_msgSend)(mgr, setup);
    }

    // (3) 启 standby 播放状态
    if ([mgr respondsToSelector:setStandby])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(mgr, setStandby, YES);

    // (4) prepare standby（gate 过才生效）
    if (![mgr respondsToSelector:standby]) { WLog(@"PROBE no -preparePictureInPictureForStandby"); return; }
    ((void (*)(id, SEL))objc_msgSend)(mgr, standby);
    WLog(@"PROBE preparePictureInPictureForStandby INVOKED");

    // (5) 真正 start PiP；传 NULL 避免 block ABI 风险，靠下面轮询确认
    if ([mgr respondsToSelector:startSel]) {
        WLog(@"PROBE calling startWithCompletionHandler:");
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, startSel, NULL);
    } else {
        WLog(@"PROBE no -startWithCompletionHandler: (依赖 prepare 的 auto-start)");
    }

    // 轮询 isActive 确认是否真建立（0.5/1/2/4/8s）
    for (NSNumber *secs in @[@(0.5), @(1.0), @(2.0), @(4.0), @(8.0)]) {
        double d = [secs doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL active = [mgr respondsToSelector:isActive]
                ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isActive) : NO;
            WLog(@"PROBE t=%.1fs isActive=%d", d, (int)active);
        });
    }
}

static void TriggerOnMain(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProbeDelegate();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WLog(@"TRIGGER firing EnsureStandbyPiP");
            EnsureStandbyPiP();
        });
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

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            WLog(@"EVT UIApplicationDidBecomeActive -> TriggerOnMain");
            TriggerOnMain();
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
