TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += psd psctl prefs

include $(THEOS_MAKE_PATH)/aggregate.mk
