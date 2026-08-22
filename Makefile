# wcvoicekeep — 微信输入法语音免跳转 (rootless / ElleKit / NathanLR / TrollFools)
# 编译方式照搬已验证的 chatswipe / wctweak：
# - TrollFools + ElleKit 只加载「链接了 substrate(=ellekit)」的 dylib，
#   故必须链接仓库内自带 CydiaSubstrate.framework（见 Frameworks/）。
# - 注入目标 com.tencent.wetype 由 TF 选 App，Filter plist 仅作 ElleKit 兜底。

export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WCVoiceKeep

WCVoiceKeep_FILES = Tweak.xm
WCVoiceKeep_FRAMEWORKS = UIKit
# 关键：链接 CydiaSubstrate(=ellekit)，TF 注入才能被 ElleKit 加载执行。
WCVoiceKeep_LDFLAGS = -Wl,-no_warn_inits -F$(THEOS_PROJECT_DIR)/Frameworks -framework CydiaSubstrate
WCVoiceKeep_CFLAGS = -fobjc-arc -fno-modules -w

# ===== 守护进程（注销/重启后自动把 Wetype 主 App 后台拉起，触发 dylib 建 PiP standby）=====
# rootless 下 TOOL_INSTALL_PATH=/usr/bin -> 实际落到 /var/jb/usr/bin/wcvoicekeep，
# 与 layout 里 com.wcvoicekeep.daemon.plist 的 Program 路径一致。
TOOL_NAME = wcvoicekeep
wcvoicekeep_FILES = daemon.m
wcvoicekeep_INSTALL_PATH = /usr/bin
wcvoicekeep_FRAMEWORKS = Foundation
# 关键：SBSLaunchApplicationWithIdentifier 需要 com.apple.springboard.launchapplications 权限，
# 不签这个 entitlement，daemon 拉 App 会被拒/被杀。
wcvoicekeep_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
