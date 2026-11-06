# 微信「后台拉起后点开黑屏」修复模块（可移植）

真源文件就在工程根目录，直接拷这两个文件走：

```
WCSceneBlackFix.h
WCSceneBlackFix.m
```

不依赖 Logos、不依赖 CydiaSubstrate，只用 UIKit + objc runtime。

---

## 它解决什么

App 被 `SBSLaunchApplicationWithIdentifier(bid, 1)`（flag=Background）后台完整拉起之后，
系统认为「已经启动过一次」，会把持久化的 scene session 恢复出来并**激活成前台**。
微信对「恢复来的旧 session」一律下发 **SubScene** 配置 → 前台是一个**没有任何可用窗口的空场景**，
系统给它铺的纯黑底就是你看到的黑屏；真正的主窗口（`iConsoleWindow` + `MainTabBarViewController`）
挂在另一条 `state=Background` 的 scene 上，系统不渲染它。

## 修复原理（纯公开 API，不自造窗口、不伪造生命周期通知）

| 序号 | 时机 | 动作 |
|---|---|---|
| ① 核心 | `-scene:willConnectToSession:options:` | scene 已创建但**还没被激活成前台**，此时把主窗口 `windowScene` 指过去 → 等系统激活它时窗口已经在上面，**没有「空场景」那一帧，零黑屏** |
| ② 可选 | `-application:configurationForConnectingSceneSession:options:` | 配置的 `name`/`delegateClass` 含 SubScene 就改写回 `MainScene`，让 App 走自己的主界面分支 |
| ③ 兜底 | `UIApplicationDidBecomeActiveNotification` + 0.4s | 结构检查：若「前台 scene 可用窗口 == 0 且主窗口挂在别的 scene」→ 立刻搬家，0.35s 复查，仍黑则回滚 |

搬家时补一次 `beginAppearanceTransition:YES` / `endAppearanceTransition`（公开的容器转场 API），
让 rootVC 重新走一遍「出现」流程 —— 少了这步会界面亮但内容不重建（微信表现为通讯录空白）。

## 用法

必须早于 `UIApplicationMain`（即 `+load` 或 `__attribute__((constructor))`）：

```objc
#import "WCSceneBlackFix.h"

__attribute__((constructor))
static void Init(void) {
    // 可选：接管日志。不设置就走 NSLog。
    // ⚠️ 回调在模块的后台串行队列执行：不要碰 UIKit / UIApplication，不要抛异常。
    WCSceneBlackFixSetLog(^(NSString *line) { YourLogFunctionAsync(line); });
    // 可选：关掉 ②（只保留 ①核心 + ③兜底）。默认 YES。
    // WCSceneBlackFixSetRewriteConfig(NO);
    WCSceneBlackFixInstall();
}
```

Theos 工程里把 .m 加进 FILES：

```make
wctweak_FILES += WCSceneBlackFix.m
```

纯净版（编译期剥离日志）：传 `-DWCF_NO_LOG=1`，或直接沿用宿主工程已有的
`-DWCVK_NO_LOG=1`（模块会自动跟随）。剥离后连字符串格式化都不做，实测 dylib 小 20%。

```make
wctweak_CFLAGS += -DWCVK_NO_LOG=$(WCVK_NO_LOG)
```

## 验证日志（装好后看这几行）

正常（零黑屏）：

```
[scene-fix] 主窗口已精准锁定: iConsoleWindow / rootVC=MainTabBarViewController（后续零查找、零通知）
[scene-fix] willConnect: 已接管 MMMainSceneDelegate（orig 就是它自己的实现）
[scene-fix] willConnect: 新场景 0x...(state=-1) 即将连接，主窗口在 0x... -> 抢先搬家
[scene-fix] 搬家完成: 主窗口 scene=0x...(state=-1) 可用窗口=1
[scene-fix] 兜底检查: ... 前台可用窗口=1 全部窗口=1
[scene-fix] 兜底检查: 界面正常，不动
```

抢搬失败（会退到 0.4s 兜底，仍有 ~0.3s 黑屏）：

```
[scene-fix] 兜底检查: 命中黑屏（前台空场景）-> 第 1 次搬家
[scene-fix] 兜底搬家成功：0.35s 内界面恢复
```

## 已验证环境

- iPhone 14 Pro Max / iOS 16 / roothide（NathanLR + ElleKit）/ TrollFools 注入
- 微信 8.0.37（com.tencent.xin）
- 2026-11-07 实机：6 个进程、10 次场景分配、10 次抢先搬家全命中，
  「判定黑屏」0 次、修复链 0 次 —— 用户反馈「基本黑屏瞬间就白屏了」

## 注意

- 本模块**只修「前台被空场景占住」**这一种黑屏形态。
  「有黑窗口盖在主窗口上」那种要另做（本机实测压制覆盖窗命中 0 次，说明不是这种）。
- `KnownSceneSessions` 文件删了没用（FBS 内存里也握一份），别走那条路。
- `requestSceneSessionActivation/Destruction` 在无 `UIApplicationSceneManifest` 的单场景 App 上
  全部同步返回「当前设备不支持多个场景」，一次都不会生效，别走那条路。
- **想再砍一个 hook**：`WCSceneBlackFixSetRewriteConfig(NO)` 可以关掉 ②（配置掰回）。
  核心的 willConnect 抢先搬家不依赖它。要关的话记得实测几轮确认仍零黑屏。

## 线程模型与运行开销（本轮优化后）

| 项 | 做法 |
|---|---|
| 日志 IO | **一律异步**：模块内部串行队列 + 宿主日志队列，文件写 / CFPreferences / NSLog 全不占主线程。主线程只做一次字符串格式化，时间戳在投递前生成，日志时序仍准确 |
| 主窗口查找 | **一次精准捕获、之后零查找**：`UIWindowDidBecomeVisibleNotification` 里用 rootVC 强特征（MainFrame/TabBar/Console/Main）锁定，命中即注销观察者；此后 `WCFMainWindow()` 快路径只是一次 `__weak` 读取，不遍历 `app.windows`、不造字符串。只有缓存尚未建立时才依次走 `delegate.window` → `keyWindow` → 一次 `app.windows` 遍历兜底（后台无头拉起时主窗口可能 hidden、不发 visible 通知，这一步保住与旧版等价的命中率），命中即缓存 |
| 全类扫描 | 仅当微信那几个 delegate 类名都不存在时才发生，且用 `class_getName` 的 C 字符串比较，不再为每个类分配 NSString |
| 兜底检查 | 1s 节流；非 headless 进程只确认一次；主窗口尚未建好时最多 3 次 0.25s 短重试；复查期间有互斥，不会叠加搬家/回滚 |
| 搬家布局 | 主窗口 `layoutIfNeeded` 保留（落地首帧）；`vc.view.frame = main.bounds` + `setNeedsDisplay` 原样保留（上屏重绘，不能砍）；只把最贵的「整棵视图树 `layoutIfNeeded`」改成尺寸真的不一致时才做 |
| 内存 | 旧 scene、主窗口缓存都是 `__weak`；回滚会还原搬家前强改的 `hidden`/`alpha` |

仍留在主线程的重活只有一件：搬家时的 `layoutIfNeeded` + `begin/endAppearanceTransition`。
这两步是公开 API 且必须同步执行（否则首帧空白 / 通讯录不重建），实测耗时约 80ms，
发生在 `willConnect` 阶段、界面还没上屏，不会造成用户可感知的卡顿。

**安全约束**：所有 UIKit 操作只走主线程（willConnect 回调、mainQueue 通知回调、dispatch_get_main_queue）。
日志队列在后台，所以日志回调里绝不能调用 UIKit。
