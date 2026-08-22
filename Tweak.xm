// wcvoicekeep — 微信输入法语音免跳转 tweak (注入 com.tencent.wetype 主 App)
// 架构（老板 2026-08-22 拍板，对照 chatswipe 链接 substrate 的方式）：
//   TF(TrollFools) 把 dylib 注入微信输入法主 App，dylib 链接 CydiaSubstrate(=ellekit)，
//   让主 App「自己拉一次悬浮窗」= 建立原生 PiP standby，键盘扩展就不跳转。
// 触发两条路：
//   A. App 变为 active(启动/切前台) -> 自动建一次
//   B. 收到 daemon 的 Darwin 通知 kTriggerName -> 再建一次(注销/respring 后兜底)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

static NSString *const kLogPath    = @"/var/mobile/wcvoicekeep.log";
static const char *const kTriggerName = "com.wcvoicekeep.pip.trigger";

static void WLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@][tweak] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) { [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    [fh closeFile];
}

// 幂等触发主 App 自建 PiP standby。私有类/方法走 objc_msgSend 强转。
static void EnsureStandbyPiP(void) {
    Class mgrCls = objc_getClass("WBVoiceInputPIPManager");
    if (!mgrCls) { WLog(@"WBVoiceInputPIPManager not found"); return; }
    if (![mgrCls respondsToSelector:@selector(sharedInstance)]) { WLog(@"no +sharedInstance"); return; }
    id mgr = ((id (*)(Class, SEL))objc_msgSend)(mgrCls, @selector(sharedInstance));
    if (!mgr) { WLog(@"sharedInstance nil"); return; }
    if ([mgr respondsToSelector:@selector(isActive)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isActive))) {
        WLog(@"PiP already active, skip");
        return;
    }
    if ([mgr respondsToSelector:@selector(isSupported)] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isSupported))) {
        WLog(@"PiP not supported on this device");
        return;
    }
    if ([mgr respondsToSelector:@selector(preparePictureInPictureForStandby)]) {
        ((void (*)(id, SEL))objc_msgSend)(mgr, @selector(preparePictureInPictureForStandby));
        WLog(@"preparePictureInPictureForStandby invoked");
    } else {
        WLog(@"no -preparePictureInPictureForStandby");
    }
}

static void TriggerOnMain(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ EnsureStandbyPiP(); });
    });
}

// ===== 路 A：App 变 active 时自动建 PiP =====
%hook AppDelegate
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    WLog(@"applicationDidBecomeActive -> ensure PiP");
    TriggerOnMain();
}
%end

// ===== 路 B：收 daemon 的 Darwin 通知再建一次 =====
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.tencent.wetype"]) return;
        WLog(@"injected into %@ (pid=%d)", bid, getpid());
        int token = 0;
        notify_register_dispatch(kTriggerName, &token, dispatch_get_main_queue(), ^(int t) {
            WLog(@"got darwin trigger -> ensure PiP");
            TriggerOnMain();
        });
    }
}
