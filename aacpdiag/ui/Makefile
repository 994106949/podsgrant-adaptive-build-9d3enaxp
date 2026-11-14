TARGET := iphone:clang:latest:13.0
ARCHS := arm64e arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PodsGrantAACPDiag

PodsGrantAACPDiag_FILES = Tweak.x \
	../shared/AACPDiagCommon.m \
	../shared/AACPDiagNative.m \
	../shared/AACPDiagRuntimeHooks.m
PodsGrantAACPDiag_CFLAGS = -fobjc-arc
PodsGrantAACPDiag_FRAMEWORKS = Foundation UIKit CoreBluetooth

include $(THEOS_MAKE_PATH)/tweak.mk
