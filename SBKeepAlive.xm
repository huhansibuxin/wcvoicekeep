// SBKeepAlive — SpringBoard 侧注入：让微信输入法(com.tencent.wetype)保持前台态
//
// 原理（参考 Immortalizer 开源，iOS 14-16.7.7 验证过的精准 hook 点）：
//   %hook FBScene -updateSettings:withTransitionContext:completion:
//   wetype 的非过渡(挂起/去激活)设置下发时，把 settings 的 deactivationReasons
//   清 0 后再 %orig —— scene 保持 active（不挂起），其他设置正常应用（状态机不卡）
//
// v1.9.26 重构（修锁屏，根因来自老板实测 + v1.9.23 对照推导）：
//   1) 删掉 UIMutableApplicationSceneSettings setDeactivationReasons 全局 hook：
//      它无 bundle 过滤——微信/所有 App 的 deactivation 全被拦 -> 微信 scene 永远
//      active -> 系统 AutoLock 暂停 -> 不锁屏（老板实测：拉起微信后不锁屏）。
//      对照 v1.9.23（只有 FBScene 拦 wetype、无全局 hook）= 锁屏正常，证明：
//      锁屏不依赖单 App scene 状态，保活只需 FBScene 专属 hook，全局 hook 有害。
//   2) FBScene 从"完全拦截 updateSettings"改为"篡改 deactivationReasons=0 再 %orig"：
//      v1.9.23 完全拦截导致 wetype scene 状态机卡死（自动拉起后不自动回后台 + 跳转）；
//      篡改后其他设置正常下发，只保持 deactivationReasons 为 0（保活），状态机正常。
//   3) 加文件日志 /var/mobile/wetypekeepalive.log（3M 上限），验证 hook 生效。
//
// 效果：wetype 一直活着且 scene 保持 active（0 CPU）；微信/其他 App 零影响；
//       系统自动锁屏正常（wetype scene active 不暂停 AutoLock，v1.9.23 验证）。

#import <Foundation/Foundation.h>
#import <objc/message.h>

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

// 读/清 settings 的 deactivationReasons（iOS16 SDK 该属性为 ULL，objc_msgSend 直调）
static unsigned long long GetDeactivationReasons(id settings) {
    if (!settings) return 0;
    SEL sel = NSSelectorFromString(@"deactivationReasons");
    if (![settings respondsToSelector:sel]) return 0;
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(settings, sel);
}
static void SetDeactivationReasonsZero(id settings) {
    if (!settings) return;
    SEL sel = NSSelectorFromString(@"setDeactivationReasons:");
    if (![settings respondsToSelector:sel]) return;
    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, sel, 0);
}

%hook FBScene

// wetype 的非过渡更新（挂起/去激活动作）：清空 deactivationReasons 保持 active，
// 然后 %orig 正常应用其他设置（不卡状态机）。其他 App / 过渡更新完全放行。
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(id)arg3 {
    id process = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"clientProcess"));
    NSString *bid = @"?";
    if (process) {
        bid = ((NSString *(*)(id, SEL))objc_msgSend)(process, NSSelectorFromString(@"bundleIdentifier"));
    }
    if ([bid isEqualToString:kWetypeBundleID] && arg2 == nil) {
        unsigned long long before = GetDeactivationReasons(arg1);
        SetDeactivationReasonsZero(arg1);
        SBLog(@"FBScene wetype non-transition update: deactivationReasons 0x%llx -> 0 (keep active)", before);
        %orig;
        return;
    }
    %orig;
}

%end

// v1.9.26：UIMutableApplicationSceneSettings setDeactivationReasons 全局 hook 已删
//（微信/锁屏元凶——无 bundle 过滤，拦了所有 App 的 deactivation）。

__attribute__((constructor)) static void SBKeepAliveInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        SBLog(@"[wetypekeepalive] CTOR loaded into %@", proc);
    }
}
