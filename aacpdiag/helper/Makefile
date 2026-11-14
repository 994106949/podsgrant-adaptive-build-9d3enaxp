TARGET := iphone:clang:latest:13.0
ARCHS := arm64e arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PodsGrantAACPDiagHelper

PodsGrantAACPDiagHelper_FILES = Tweak.x \
	../shared/AACPDiagCommon.m \
	../shared/AACPDiagNative.m \
	../shared/AACPDiagRuntimeHooks.m \
	../shared/AACPDiagTransport.m
PodsGrantAACPDiagHelper_CFLAGS = -fobjc-arc
PodsGrantAACPDiagHelper_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
