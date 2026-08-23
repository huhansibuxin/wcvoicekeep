// SBKeepAlive — SpringBoard 侧注入：让微信输入法(com.tencent.wetype)保持前台态
//
// 原理（参考 Immortalizer 开源，iOS 14-16.7.7 验证过的精准 hook 点）：
//   %hook FBScene -updateSettings:withTransitionContext:completion:
//   当场景属于 wetype 且 transitionContext==nil（非过渡=挂起动作）时 return，
//   不调用 %orig —— SpringBoard 无法把 wetype 场景切到 deactivated -> 进程不被挂起
//   （FBScene 拦截对 wetype 专属精准，已足够阻止挂起 + scene 保持 active）
//
// v1.9.23：删掉 UIMutableApplicationSceneSettings setDeactivationReasons 全局 hook——
// 它拦截所有 scene 的 deactivation 原因（arg1!=0 全拦），锁屏时系统要给 scene 设
// 锁屏 deactivation 原因也被拦 -> scene 永不 deactivate -> 自动锁屏被挂起
// （老板实测：首次解锁后不自动锁屏）。FBScene 专属 hook 已够，全局 hook 有害。
//
// 效果：wetype 一直活着且 scene 保持 active（0 CPU，只是不被 SIGSTOP/去激活）
//   -> 微信视频 PiP 顶掉 wetype PiP 时系统走 suspended（offscreen）而非销毁
//   -> 微信视频结束，系统自动恢复 wetype PiP（Apple 文档保证，进程活着）
//   -> 即使不自动恢复，dylib 在 scene active 下也能后台重建 PiP（UIScene 检查可过）
//
// v1.9.18 融合进 wcvoicekeep deb（老板要求避免多插件冲突）。

#import <Foundation/Foundation.h>
#import <objc/message.h>

// theos SDK 无 SpringBoard 私有头，声明存根类即可（运行时真实类名匹配）
@interface FBScene : NSObject
@end
@interface FBProcess : NSObject
@end

static NSString *const kWetypeBundleID = @"com.tencent.wetype";

%hook FBScene

// 阻止 SpringBoard 对 wetype 下发"去激活"场景设置（即阻止挂起）
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(id)arg3 {
    id process = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"clientProcess"));
    if (process) {
        NSString *bid = ((NSString *(*)(id, SEL))objc_msgSend)(process, NSSelectorFromString(@"bundleIdentifier"));
        if ([bid isEqualToString:kWetypeBundleID] && arg2 == nil) {
            // 非过渡更新 + wetype：拦截，不下发 deactivation（不挂起）
            return;
        }
    }
    %orig;
}

%end

// v1.9.24：恢复 setDeactivationReasons hook（v1.9.22 行为，保证自动回后台+PiP 恢复），
// 但精准放行锁屏——arg1 含 UISceneDeactivationReasonLocked(1<<2=0x4) 时放行 %orig
//（允许系统锁屏），其他 deactivation 原因（切后台等）拦截保持 scene active。
// 修复 v1.9.23 删掉后"自动拉起不自动回后台 + 还跳转"；同时不破坏自动锁屏。
%hook UIMutableApplicationSceneSettings

- (void)setDeactivationReasons:(unsigned long long)arg1 {
    if (arg1 != 0 && !(arg1 & (1ull << 2))) return; // 非锁屏原因拦；锁屏原因放行
    %orig;
}

%end

__attribute__((constructor)) static void SBKeepAliveInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSLog(@"[wetypekeepalive] CTOR loaded into %@", proc);
    }
}
