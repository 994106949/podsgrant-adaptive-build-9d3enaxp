TARGET := iphone:clang:latest:13.0
ARCHS := arm64e arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = aacpdiagd
aacpdiagd_FILES = main.m \
	../shared/AACPDiagCommon.m \
	../shared/AACPDiagTransport.m
aacpdiagd_CFLAGS = -fobjc-arc -DAACPDIAG_TRANSPORT_NO_ACTIVE_FD=1
aacpdiagd_FRAMEWORKS = Foundation
aacpdiagd_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
