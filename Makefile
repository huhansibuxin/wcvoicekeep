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

include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
