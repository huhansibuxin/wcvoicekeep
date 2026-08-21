export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TOOL_NAME = wcvoicekeep

wcvoicekeep_FILES = daemon.m
wcvoicekeep_CFLAGS = -fobjc-arc
wcvoicekeep_CODESIGN_FLAGS = -Sentitlements.plist
wcvoicekeep_INSTALL_PATH = /usr/bin

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
