// wcvoicekeep — 注入微信输入法主 App (com.tencent.wetype)
// 目标：主 App 一旦前台激活（被 daemon 或用户拉起），立即建立并常驻 PiP standby，
//       让键盘扩展侧 -[WBVoiceInputService requireJumpToMainAppForRecording] 恒返回 0，
//       从而语音输入「零前台跳转」。
//
// === 逆向依据（capstone 静态分析 wxkb 主二进制）===
//   键盘扩展: requireJumpToMainAppForRecording
//              -> isMainAppVoiceStandbyActive
//              -> [WBVoiceStateProbe pictureInPictureActive] (= appAlive && mask.bit1)
//   状态由主 App 经 WBWormhole(App Group group.com.tencent.wetype) 心跳上报。
//   主 App 建 standby 的原生入口:
//     [[WBVoiceInputPIPManager sharedInstance] preparePictureInPictureForStandby]
//       -> setStandbyPlaybackStateEnabled:1 -> (自动)startPictureInPicture
//   PiP 只能在前台 scene 建立(findAnchorWindow 需 foreground)，故必须在
//   applicationDidBecomeActive 之后触发一次；建成后主 App 靠原生
//   UIBackgroundModes:audio + PiP 常驻后台。
//
// 本 tweak 只调用主 App 自己的公开路径建 standby，不改任何判定逻辑、不伪造状态。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kLogPath = @"/var/mobile/wcvoicekeep.log";

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

// 幂等触发主 App 自建 PiP standby。私有类/方法一律走 objc_msgSend 强转，避免编译期未知选择器报错。
static void EnsureStandbyPiP(void) {
    Class mgrCls = objc_getClass("WBVoiceInputPIPManager");
    if (!mgrCls) { WLog(@"WBVoiceInputPIPManager not found, skip"); return; }

    SEL shared = @selector(sharedInstance);
    if (![mgrCls respondsToSelector:shared]) { WLog(@"no +sharedInstance"); return; }
    id mgr = ((id (*)(Class, SEL))objc_msgSend)(mgrCls, shared);
    if (!mgr) { WLog(@"sharedInstance nil"); return; }

    // 已激活就不重复建立
    SEL isActive = @selector(isActive);
    if ([mgr respondsToSelector:isActive]) {
        BOOL active = ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isActive);
        if (active) { WLog(@"PiP already active, skip"); return; }
    }

    SEL isSupported = @selector(isSupported);
    if ([mgr respondsToSelector:isSupported]) {
        BOOL sup = ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isSupported);
        if (!sup) { WLog(@"PiP not supported on this device"); return; }
    }

    SEL prep = @selector(preparePictureInPictureForStandby);
    if ([mgr respondsToSelector:prep]) {
        ((void (*)(id, SEL))objc_msgSend)(mgr, prep);
        WLog(@"preparePictureInPictureForStandby invoked");
    } else {
        WLog(@"no -preparePictureInPictureForStandby");
    }
}

%hook AppDelegate
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    // 延后到 runloop，确保 scene/window 已就绪，PiP anchor 可用
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        EnsureStandbyPiP();
    });
}
%end
