export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

# --- daemon (LaunchDaemon 拉起+重建微信输入法主App) ---
TOOL_NAME = wcvoicekeep
wcvoicekeep_FILES = daemon.m
wcvoicekeep_CFLAGS = -fobjc-arc
wcvoicekeep_CODESIGN_FLAGS = -Sentitlements.plist
wcvoicekeep_INSTALL_PATH = /usr/bin

# --- 只读探针 tweak (注入 com.tencent.wetype，捞入口 selector) ---
TWEAK_NAME = WCIntrospect
WCIntrospect_FILES = Tweak.xm
WCIntrospect_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
