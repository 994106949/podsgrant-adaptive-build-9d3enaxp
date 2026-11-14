TARGET := iphone:clang:latest:13.0
ARCHS := arm64e arm64
INSTALL_TARGET_PROCESSES = Preferences bluetoothd heard

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += ui helper daemon
include $(THEOS_MAKE_PATH)/aggregate.mk
