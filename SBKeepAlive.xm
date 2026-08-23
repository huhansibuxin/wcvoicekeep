// SBKeepAlive — SpringBoard 侧注入：让微信输入法(com.tencent.wetype)保持前台态
//
// 原理（参考 Immortalizer 开源，iOS 14-16.7.7 验证过的精准 hook 点）：
//   1) %hook FBScene -updateSettings:withTransitionContext:completion:
//      当场景属于 wetype 且 transitionContext==nil（非过渡=挂起动作）时 return，
//      不调用 %orig —— SpringBoard 无法把 wetype 场景切到 deactivated -> 进程不被挂起
//   2) %hook UIMutableApplicationSceneSettings -setDeactivationReasons:
//      arg1 != 0 时 return —— 阻止任何"非活跃原因"被设置 -> scene 保持 active
//      （Immortalizer 原版全局拦截，实测稳定）
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

%hook UIMutableApplicationSceneSettings

// 阻止设置任何"非活跃原因"——scene 保持 active（Immortalizer 原版全局拦截）
- (void)setDeactivationReasons:(unsigned long long)arg1 {
    if (arg1 != 0) return;
    %orig;
}

%end

__attribute__((constructor)) static void SBKeepAliveInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSLog(@"[wetypekeepalive] CTOR loaded into %@", proc);
    }
}
