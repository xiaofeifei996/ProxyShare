include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ProxySharePrefs
ProxySharePrefs_INSTALL_PATH = /Library/PreferenceBundles
ProxySharePrefs_FILES = ../Prefs/PSShareController.m
ProxySharePrefs_FRAMEWORKS = UIKit Foundation
ProxySharePrefs_PRIVATE_FRAMEWORKS = Preferences
ProxySharePrefs_CFLAGS = -fobjc-arc -O2 -Wall
ProxySharePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
