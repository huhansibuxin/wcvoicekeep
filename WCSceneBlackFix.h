//
//  WCSceneBlackFix.h
//
//  「App 被后台无头拉起后，用户点开黑屏」通用修复模块。
//
//  适配场景（已在微信 iOS 16 / roothide 实机验证）：
//    某 App 被 SBSLaunchApplicationWithIdentifier(bid, 1) 以 Background flag 拉起后，
//    系统会把它当作「已启动过一次」，并把持久化的 scene session 恢复出来、激活成前台。
//    App 此时把恢复来的旧 session 一律下发 SubScene 配置（而不是 MainScene），
//    于是前台是一个**没有任何可用窗口的空场景**，系统给它铺的纯黑底就是用户看到的黑屏；
//    真正的主窗口（有 rootVC 的那个）挂在另一条 state=Background 的 scene 上，系统不渲染。
//
//  修复原理（纯公开 API，不自造窗口、不伪造生命周期通知）：
//    1) 【核心】hook 场景 delegate 的 -scene:willConnectToSession:options:
//       此时 scene 对象已创建但**还没被激活成前台**。在这个时刻把主窗口的 windowScene
//       指向它，等系统激活它时窗口已经在上面了 → 没有「空场景」那一帧 → 零黑屏。
//    2) 【可选】hook -application:configurationForConnectingSceneSession:options:
//       把 name / delegateClass 里含 SubScene 的配置改写回 MainScene，让 App 走自己的主界面分支。
//    3) 【兜底】UIApplicationDidBecomeActiveNotification 后 0.4s 做一次结构检查：
//       若「前台 scene 可用窗口 == 0 且主窗口挂在别的 scene」→ 立刻搬家并复查，仍黑则回滚。
//       抢搬万一失败（scene 仍处于 Unattached 时设 windowScene 可能被延迟处理）由它救回来。
//
//  用法（必须早于 UIApplicationMain，即 +load 或 __attribute__((constructor))）：
//      #import "WCSceneBlackFix.h"
//      WCSceneBlackFixSetLog(^(NSString *line){ NSLog(@"[SceneBlackFix] %@", line); });
//      WCSceneBlackFixInstall();
//

#ifndef WCSceneBlackFix_h
#define WCSceneBlackFix_h

#import <Foundation/Foundation.h>

/// 安装修复。重复调用安全（内部只装一次）。
void WCSceneBlackFixInstall(void);

/// 接管日志（传 nil = 只走 NSLog）。日志量很小，只在关键动作时输出。
/// ★ 日志一律投递到模块内部的串行队列执行，磁盘 IO / CFPreferences / NSLog
///   绝不占主线程；主线程只做一次字符串格式化。日志顺序按产生顺序保持。
/// ⚠️ 回调在后台队列执行：不要触碰 UIKit / UIApplication，不要抛异常
///   （模块已做 @try 隔离）。代价是进程被强杀时可能丢最后几条日志。
void WCSceneBlackFixSetLog(void (^handler)(NSString *line));

/// 是否把「子场景配置」改写回「主场景配置」。默认 YES。
/// 关掉只影响 scene 配置的 name/delegateClass，核心的抢先搬家仍然生效。
void WCSceneBlackFixSetRewriteConfig(BOOL on);

#endif /* WCSceneBlackFix_h */
