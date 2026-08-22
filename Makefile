export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

# --- daemon (LaunchDaemon: 保活主App + 发Darwin通知触发dylib建PiP) ---
TOOL_NAME = wcvoicekeep
wcvoicekeep_FILES = daemon.m
wcvoicekeep_CFLAGS = -fobjc-arc
wcvoicekeep_CODESIGN_FLAGS = -Sentitlements.plist
wcvoicekeep_INSTALL_PATH = /usr/bin

# --- dylib (TrollFools 注入进微信输入法主App，无substrate依赖) ---
# 用 LIBRARY 而非 TWEAK：不链接 CydiaSubstrate、不装进 DynamicLibraries，
# 产物是一个干净的 .dylib，交给 TrollFools 手动注入到 com.tencent.wetype。
LIBRARY_NAME = libwcvoicekeep
libwcvoicekeep_FILES = inject.m
libwcvoicekeep_CFLAGS = -fobjc-arc
libwcvoicekeep_INSTALL_PATH = /usr/lib
libwcvoicekeep_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/library.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
