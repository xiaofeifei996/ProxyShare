TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = 

include $(THEOS)/makefiles/common.mk

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

# ============================================================ 设置面板
# 独立 Preferences bundle，由 Settings.app 在 mobile 用户下加载。
# 它不直接读写文件，而是通过 127.0.0.1 控制端口与 root 守护进程通信。

BUNDLE_NAME = ProxySharePrefs
ProxySharePrefs_INSTALL_PATH = /Library/PreferenceBundles
ProxySharePrefs_FILES = Prefs/PSShareController.m
ProxySharePrefs_FRAMEWORKS = UIKit Foundation
ProxySharePrefs_PRIVATE_FRAMEWORKS = Preferences
ProxySharePrefs_CFLAGS = -fobjc-arc -I Sources -O2 -Wall
ProxySharePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

# 面板自己的资源（Root.plist 等）随 bundle 安装
ProxySharePrefs_RESOURCE_DIRS = Prefs/Resources

after-ProxySharePrefs-all::
	@echo "=== ProxySharePrefs bundle 构建完成 ==="
