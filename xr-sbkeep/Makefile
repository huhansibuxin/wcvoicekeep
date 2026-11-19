# xr-sbkeep / XR 微信持续运行 —— 1.2.0
#
# 老板 2026-11-19 定案：XR 放在屋里、没人解锁，微信掉了必须自动拉起并「一直跑」。
# 光靠 daemon 拉起只是「进程存在但被 suspend」（CPU 为 0），所以这一层注入 SpringBoard：
#   ① RBSAssertion（PreventTaskSuspend）让 RunningBoard 不挂起微信 —— 解锁/锁屏都生效
#   ② 锁屏期额外扶持场景（setForeground=YES / setBackgrounded=NO），避免被 secure lockscreen 退后台
#
# rootful（不设 THEOS_PACKAGE_SCHEME），TARGET 最低 iOS 14.0，与 roothide 主工程完全隔离。

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XRWeChatKeep
XRWeChatKeep_FILES = Tweak.m
XRWeChatKeep_CFLAGS = -fobjc-arc -fno-modules -w
# 纯 ObjC runtime swizzle，不用 Logos、不链接也不引用 libsubstrate，任何越狱都能加载
XRWeChatKeep_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
