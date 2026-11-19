# wcvoicekeep lite —— 只保活微信（com.tencent.xin）
#
# 目标设备：iPhone XR / iOS 14.6 / rootful 越狱（/ 根目录，非 /var/jb、非 roothide）
# 刻意不做（老板 2026-11-19 定案）：设置页 / PreferenceLoader / AltList / SpringBoard 注入 /
#   键盘扩展 wxkb_plugin / 记录 plist / 任何第三方依赖。因此本包 Depends 只有 firmware >= 14.0。
#
# 与主工程（../Makefile，roothide + iOS 16）完全独立：根 Makefile 不 include 本目录，互不影响。

# rootful：不设 THEOS_PACKAGE_SCHEME（空 = 原生根布局，装到 /Library/LaunchDaemons、/usr/bin）
export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
export ERROR_ON_WARNINGS = 0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = wcvoicekeeplite
wcvoicekeeplite_FILES = daemon.m
wcvoicekeeplite_INSTALL_PATH = /usr/bin
wcvoicekeeplite_FRAMEWORKS = Foundation
# SBSLaunchApplicationWithIdentifier 需要 com.apple.springboard.launchapplications
wcvoicekeeplite_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements.plist
wcvoicekeeplite_CFLAGS = -fobjc-arc -fno-modules -w -DWCLITE_NO_LOG
# 纯净版：编译期关闭全部日志（不 open 文件、不写盘）。要出诊断版就删掉 -DWCLITE_NO_LOG。

include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
