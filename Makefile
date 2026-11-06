# wcvoicekeep / 后台保活 —— 2.0.0
#
# 架构（2.0.0 大改，老板 2026-11-06 定案）：
#   * 只管「后台保活」：键盘扩展 wxkb_plugin + 用户在设置里勾选的任意 App
#   * 微信输入法主程序（com.tencent.wetype）的 PiP 保活整套**已删除**（输入法更新后不再需要）
#   * 事件驱动：daemon 给每个目标单独挂内核进程退出事件（DISPATCH_PROC_EXIT），零轮询
#   * 完全后台拉起：SBSLaunchApplicationWithIdentifier(bid, 1)（flag=Background，不切前台）
#   * 设置页：wcvkprefs（PreferenceLoader bundle，结构照 notification-island-persist/niprefs）
#
# 双版本编译（照 wctweak 流程）：
#   环境变量 WCVK_NO_LOG=1 -> 编译期剥掉所有日志埋点（纯净版 pure）；=0 -> 带日志版（log）
#   CI 用 matrix flavor [log, pure] 各出一份 deb。
#
# 编译方式照搬已验证的 chatswipe / wctweak：
# - TrollFools + ElleKit 只加载「链接了 substrate(=ellekit)」的 dylib，
#   故必须链接仓库内自带 CydiaSubstrate.framework（见 Frameworks/）。

export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64 arm64e
# 老板设备 = roothide 隐根；必须配合 roothide 官方 fork 的 theos（普通 theos 不认该 scheme）
export THEOS_PACKAGE_SCHEME = roothide
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

# 日志开关：CI 传 1 出纯净版；本地/默认 0 出带日志版
WCVK_NO_LOG ?= 0
export WCVK_NO_LOG

include $(THEOS)/makefiles/common.mk

# ===== SpringBoard 侧：唯一职责 = 被 daemon 叫醒时把键盘弹一下，让系统把 wxkb_plugin 拉起来 =====
# （2.0.0 删除了原来的 FBScene PiP 保活 —— 那是给微信输入法主程序用的，现在整套不要了）
TWEAK_NAME = wetypekeepalive
wetypekeepalive_FILES = SBKeepAlive.xm
wetypekeepalive_FRAMEWORKS = UIKit Foundation
wetypekeepalive_LDFLAGS = -Wl,-no_warn_inits -F$(THEOS_PROJECT_DIR)/Frameworks -framework CydiaSubstrate
wetypekeepalive_CFLAGS = -fobjc-arc -fno-modules -w -DWCVK_NO_LOG=$(WCVK_NO_LOG)

# ===== 守护进程：事件驱动看护 + 后台拉起 =====
# roothide 下落到 /usr/bin/wcvoicekeep（与 layout 里 LaunchDaemons 的 Program 路径一致）
TOOL_NAME = wcvoicekeep
wcvoicekeep_FILES = daemon.m
wcvoicekeep_INSTALL_PATH = /usr/bin
# Foundation + MobileCoreServices：LSApplicationWorkspace / LSApplicationProxy 解析 App 可执行路径
wcvoicekeep_FRAMEWORKS = Foundation MobileCoreServices
# SBSLaunchApplicationWithIdentifier 需要 com.apple.springboard.launchapplications 权限
wcvoicekeep_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements.plist
wcvoicekeep_CFLAGS = -fobjc-arc -fno-modules -w -DWCVK_NO_LOG=$(WCVK_NO_LOG)

# ===== 注入微信侧：后台预热黑屏 诊断 + 四级修复（2.0.9）=====
# TrollFools 注入 com.tencent.xin（也可随 deb 装到 DynamicLibraries，靠 wcprewarmfix.plist 限定只注入微信）
# 目的：daemon 后台拉起微信后点开黑屏 —— 从 App 内部检查主窗口健康度并逐级修复
#
# ⚠️ v2.0.13 关键修复：**这份 dylib 绝对不能链接 CydiaSubstrate**。
# 之前照 SBKeepAlive 的写法加了 `-F$(THEOS_PROJECT_DIR)/Frameworks -framework CydiaSubstrate`，
# 生成出来的依赖是 `@loader_path/.jbroot/usr/lib/libsubstrate.dylib` —— 相对路径，
# 在 TrollFools 注入环境里展开成 WeChat.app/Frameworks/.jbroot/usr/lib/libsubstrate.dylib，
# 在 ElleKit 环境里展开成 /var/jb/Library/MobileSubstrate/DynamicLibraries/.jbroot/...，**两处都不存在**
# → dlopen 直接失败 → %ctor 一次都没执行 → 日志文件/系统日志全空（老板实测就是这样）。
# 本文件只用 %ctor + NSNotificationCenter + UIKit 调用，**没有任何 %hook/%orig/%group**，
# 不需要 substrate；去掉依赖后只依赖系统库，注入即生效。
# ⚠️ v2.0.15：文件是 .m 不是 .xm —— 本文件不用任何 %hook/%orig/%group，
# 之前写成 .xm + %ctor 编出来的 dylib 是空壳（__TEXT 只有 Mach-O 头、
# 链接报 no debug symbols），注入后一行代码都不执行，日志自然永远为空。
# 同工程 wetypekeepalive 用 __attribute__((constructor)) 一直正常，照它来即可。
wcprewarmfix_FILES = WCPrewarmFix.m WCSceneBlackFix.m
wcprewarmfix_FRAMEWORKS = UIKit Foundation
wcprewarmfix_LDFLAGS = -Wl,-no_warn_inits
wcprewarmfix_CFLAGS = -fobjc-arc -fno-modules -w -DWCVK_NO_LOG=$(WCVK_NO_LOG)
TWEAK_NAME = wetypekeepalive wcprewarmfix

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

# ===== 设置页（显示名「后台保活」）=====
SUBPROJECTS += wcvkprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
