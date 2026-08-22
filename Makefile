export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

# --- daemon (LaunchDaemon: 保活主App + 发Darwin通知触发dylib建PiP) ---
# 关键：daemon 必须编成纯 arm64（非 arm64e）。rootless 下 ad-hoc 签名的
# arm64e 守护进程过不了 AMFI/PAC 校验 → 被 SIGKILL(exit 137, OS_REASON_EXEC)，
# launchd 反复重启永远起不来。设备上能常驻的 sshd 就是纯 arm64。
TOOL_NAME = wcvoicekeep
wcvoicekeep_FILES = daemon.m
wcvoicekeep_ARCHS = arm64
wcvoicekeep_CFLAGS = -fobjc-arc
wcvoicekeep_CODESIGN_FLAGS = -Sentitlements.plist
wcvoicekeep_INSTALL_PATH = /usr/bin

# --- dylib (TrollFools 注入进微信输入法主App，无substrate依赖) ---
# 架构必须与宿主一致。实测本机 wxkb 主二进制是纯 arm64 (ARMv8, 无PAC)，
# 不是 arm64e -> dylib 必须编 arm64，否则 dyld 架构不匹配、根本不加载，
# constructor 不执行、日志无 injected。(之前误编 arm64e 导致注入无效)
LIBRARY_NAME = libwcvoicekeep
libwcvoicekeep_FILES = inject.m
libwcvoicekeep_ARCHS = arm64
libwcvoicekeep_CFLAGS = -fobjc-arc
libwcvoicekeep_INSTALL_PATH = /usr/lib
libwcvoicekeep_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/library.mk

before-package::
	@chmod 755 layout/DEBIAN/postinst
