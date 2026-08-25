// SBKeepAlive — SpringBoard 侧注入：让微信输入法(com.tencent.wetype)保持前台态
//
// v1.9.27（修 v1.9.26 篡改式失败，根因来自 SSH 日志铁证）：
//   v1.9.26 篡改式（清 deactivationReasons 再 %orig）实测双失败：
//     1) 保活退化：PiP 打断后恢复慢（15:11:00 lost -> 15:11:56 才 built，56s）
//     2) 锁屏还是不行：FBScene 日志显示 wetype 的 deactivationReasons 恒 0x20，
//        被清 0 后系统认为 wetype 在播"活跃内容" -> idle timer 暂停 -> 不锁屏
//
//   v1.9.23 对照（完全拦截 + 无全局 hook）= 锁屏正常 -> 锁屏不依赖单 App scene，
//   只拦 wetype 的 deactivation 不影响锁屏。所以：
//
//   v1.9.27 组合：
//   1) FBScene 完全拦截（回 v1.9.24/25 保活主路径）：wetype 非过渡更新直接 return
//      不 %orig -> scene 永 active -> 保活完整（PiP 打断秒级恢复）
//   2) setDeactivationReasons 从"全局拦"改"标记拦"：FBScene 拦截时把 wetype 的
//      settings 打 associated object 标记；hook 里只拦带标记的（wetype），
//      微信/其他 App 完全放行 -> 锁屏恢复（不再猜锁屏 bit，v1.9.23 实证）
//   3) 文件日志 /var/mobile/wetypekeepalive.log（3M 上限）

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>   // objc_setAssociatedObject

// theos SDK 无 SpringBoard 私有头，声明存根类即可（运行时真实类名匹配）
@interface FBScene : NSObject
@end
@interface FBProcess : NSObject
@end

static NSString *const kWetypeBundleID = @"com.tencent.wetype";

// ===== 文件日志（SB 进程 mobile 用户写 /var/mobile/，3M 上限）=====
static void SBLog(NSString *fmt, ...) {
    static NSString *path = @"/var/mobile/wetypekeepalive.log";
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > 3 * 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// wetype 的 settings 标记（FBScene 拦截时打上，setDeactivationReasons 据此只拦 wetype）
static char kIsWetypeSettingsKey;

%hook FBScene

// wetype 的非过渡更新（挂起/去激活动作）：完全拦截不 %orig（scene 永 active），
// 并标记 settings 供 setDeactivationReasons 精准判断。其他 App / 过渡更新放行。
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(id)arg3 {
    id process = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"clientProcess"));
    NSString *bid = @"?";
    if (process) {
        bid = ((NSString *(*)(id, SEL))objc_msgSend)(process, NSSelectorFromString(@"bundleIdentifier"));
    }
    if ([bid isEqualToString:kWetypeBundleID] && arg2 == nil) {
        objc_setAssociatedObject(arg1, &kIsWetypeSettingsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SBLog(@"FBScene wetype non-transition update BLOCKED (keep active)");
        return; // 完全拦截：不 %orig，scene 保持 active
    }
    %orig;
}

%end

// 只拦 wetype 的 deactivationReasons（带标记的 settings）——微信/其他 App 完全放行，
// 锁屏恢复正常（v1.9.23 实证：只拦 wetype 的 deactivation 不影响系统锁屏）。
%hook UIMutableApplicationSceneSettings

- (void)setDeactivationReasons:(unsigned long long)arg1 {
    NSNumber *isWetype = objc_getAssociatedObject(self, &kIsWetypeSettingsKey);
    if ([isWetype boolValue] && arg1 != 0) {
        SBLog(@"setDeactivationReasons 0x%llx BLOCKED (wetype settings only)", arg1);
        return;
    }
    %orig;
}

%end

__attribute__((constructor)) static void SBKeepAliveInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        SBLog(@"[wetypekeepalive] CTOR loaded into %@", proc);
    }
}
