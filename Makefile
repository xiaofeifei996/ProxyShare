TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = 

include $(THEOS)/makefiles/common.mk

TOOL_NAME = psd

psd_FILES = Daemon/main.m Sources/PSConfig.m Sources/PSProxyServer.m
psd_FRAMEWORKS = Foundation
psd_CFLAGS = -fobjc-arc -I Sources -O2 -Wall
psd_LDFLAGS = -lobjc
psd_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
