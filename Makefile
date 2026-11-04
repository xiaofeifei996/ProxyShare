TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = 

include $(THEOS)/makefiles/common.mk

# ============================================================ 守护进程
TOOL_NAME = psd

psd_FILES = Daemon/main.m \
            Sources/PSConfig.m \
            Sources/PSProxyServer.m \
            Sources/PSControlServer.m
psd_FRAMEWORKS = Foundation
psd_CFLAGS = -fobjc-arc -I Sources -O2 -Wall
psd_LDFLAGS = -lobjc
psd_INSTALL_PATH = /usr/libexec
psd_CODESIGN_FLAGS = -Spsd.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

# ============================================================ 命令行工具
TOOL_NAME = psctl

psctl_FILES = PSCTL/main.m
psctl_FRAMEWORKS = Foundation
psctl_CFLAGS = -fobjc-arc -O2 -Wall
psctl_LDFLAGS = -lobjc
psctl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk

# ============================================================ 设置面板
BUNDLE_NAME = ProxySharePrefs
ProxySharePrefs_INSTALL_PATH = /Library/PreferenceBundles
ProxySharePrefs_FILES = Prefs/PSShareController.m
ProxySharePrefs_FRAMEWORKS = UIKit Foundation
ProxySharePrefs_PRIVATE_FRAMEWORKS = Preferences
ProxySharePrefs_CFLAGS = -fobjc-arc -I Sources -O2 -Wall
ProxySharePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
