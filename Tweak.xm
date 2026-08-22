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

// 幂等触发主 App 自建 PiP standby，并探测每一步是否成功
static void EnsureStandbyPiP(void) {
    Class mgrCls = objc_getClass("WBVoiceInputPIPManager");
    if (!mgrCls) { WLog(@"PROBE WBVoiceInputPIPManager runtime class NOT FOUND"); return; }
    WLog(@"PROBE WBVoiceInputPIPManager found = %@", mgrCls);

    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (![mgrCls respondsToSelector:shared]) { WLog(@"PROBE no +sharedInstance"); return; }
    id mgr = ((id (*)(Class, SEL))objc_msgSend)(mgrCls, shared);
    if (!mgr) { WLog(@"PROBE sharedInstance nil"); return; }

    SEL isActive    = NSSelectorFromString(@"isActive");
    SEL isSupported = NSSelectorFromString(@"isSupported");
    WLog(@"PROBE mgr=%@ responds isActive=%d isSupported=%d",
         mgr,
         (int)[mgr respondsToSelector:isActive],
         (int)[mgr respondsToSelector:isSupported]);

    SEL standby = NSSelectorFromString(@"preparePictureInPictureForStandby");
    if (![mgr respondsToSelector:standby]) { WLog(@"PROBE no -preparePictureInPictureForStandby"); return; }

    ((void (*)(id, SEL))objc_msgSend)(mgr, standby);
    WLog(@"PROBE preparePictureInPictureForStandby INVOKED on %@", mgr);

    // 2s 后回查是否真变成 active，确认调用真的生效
    if ([mgr respondsToSelector:isActive]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL active = ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isActive);
            WLog(@"PROBE isActive after 2s = %d  (1=已建立 standby)", (int)active);
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
