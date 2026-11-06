include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = BackgroundKeepPrefs

BackgroundKeepPrefs_FILES = BKRootListController.m
BackgroundKeepPrefs_INSTALL_PATH = /Library/PreferenceBundles
BackgroundKeepPrefs_FRAMEWORKS = UIKit
# AltList 不做链接依赖：ATL 控制器只是 Root.plist detail 里的类名字符串，代码零符号引用；
# 进页面时由 BKRootListController 运行时 dlopen 系统安装的那份（dladdr 自定位真实 jbroot，
# 随机串自动适配）——bundle 加载零 AltList 依赖，不打包不冲突不增体积。
BackgroundKeepPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# 16.5 社区 SDK 没有 Preferences.tbd：Preferences/AltList 的链接符号全部运行时解析
# （notification-island-persist 已验证的路子；settings 进程里这些符号天然存在）
BackgroundKeepPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/BackgroundKeepPrefs.plist$(ECHO_END)
