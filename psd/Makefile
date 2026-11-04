include $(THEOS)/makefiles/common.mk

TOOL_NAME = psd
psd_FILES = ../Daemon/main.m ../Sources/PSConfig.m ../Sources/PSProxyServer.m ../Sources/PSControlServer.m
psd_FRAMEWORKS = Foundation
psd_CFLAGS = -fobjc-arc -I../Sources -O2 -Wall
psd_LDFLAGS = -lobjc
psd_INSTALL_PATH = /usr/libexec
psd_CODESIGN_FLAGS = -S../psd.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
