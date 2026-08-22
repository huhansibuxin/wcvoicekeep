// wcvoicekeep — TrollFools 注入进微信输入法主 App (com.tencent.wetype) 的 dylib
//
// 设计（老板 2026-08-22 拍板）：
//   走 TF 注入 = dylib 成为 app 签名的一部分，绕过微信反注入自杀（区别于
//   NathanLR/MobileSubstrate 运行时 dlopen，那种会被检测到 → 主 App 闪退）。
//   本 dylib 零 substrate 依赖：不 %hook、不链接 CydiaSubstrate，只用
//   constructor + NSNotificationCenter + CFNotificationCenter(Darwin)，
//   TF 注入后无需 ellekit/substrate，痕迹最小。
//
// 职责：让主 App「自己拉一次悬浮窗」= 建立它原生的 PiP standby。
//   逆向依据(capstone wxkb)：
//     [[WBVoiceInputPIPManager sharedInstance] preparePictureInPictureForStandby]
//       -> setStandbyPlaybackStateEnabled:1 -> (自动) startPictureInPicture
//   PiP 只能在前台 scene 建立(findAnchorWindow 需 foreground)，故触发点选在
//   applicationDidBecomeActive 之后。
//   一旦 standby 活，键盘扩展 requireJumpToMainAppForRecording 恒返回 0 → 零跳转。
//
// 触发两条路：
//   A. 主 App 变为 active(启动/切前台) -> 自动建一次
//   B. 收到 daemon 发来的 Darwin 通知 kTriggerName -> 再建一次(注销/respring 后兜底)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

static NSString *const kLogPath   = @"/var/mobile/wcvoicekeep.log";
// daemon <-> dylib 约定的 Darwin 通知名（两边必须一致）
static NSString *const kTriggerName = @"com.wcvoicekeep.pip.trigger";

static void WLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@][dylib] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) { [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    [fh closeFile];
}

// 幂等触发主 App 自建 PiP standby。私有类/方法全走 objc_msgSend 强转。
static void EnsureStandbyPiP(void) {
    Class mgrCls = objc_getClass("WBVoiceInputPIPManager");
    if (!mgrCls) { WLog(@"WBVoiceInputPIPManager not found (bundle not wxkb?)"); return; }
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
        // 延后确保 scene/window 就绪，PiP anchor 可用
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ EnsureStandbyPiP(); });
    });
}

__attribute__((constructor))
static void wcvk_init(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        // 只在主 App 内工作；键盘扩展/其它容器直接跳过（防 TF 误注入到扩展）
        if (![bid isEqualToString:@"com.tencent.wetype"]) {
            return;
        }
        WLog(@"injected into %@ (pid=%d)", bid, getpid());

        // 路 A：app active 时自动建 PiP
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
            WLog(@"DidBecomeActive -> ensure PiP");
            TriggerOnMain();
        }];

        // 路 B：收到 daemon 的 Darwin 通知时再建一次
        int token = 0;
        notify_register_dispatch([kTriggerName UTF8String], &token,
                                 dispatch_get_main_queue(), ^(int t) {
            WLog(@"got darwin trigger -> ensure PiP");
            TriggerOnMain();
        });
    }
}
