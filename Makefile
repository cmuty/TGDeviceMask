ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Telegram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TGDeviceMask
TGDeviceMask_FILES = Tweak.x
TGDeviceMask_CFLAGS = -fobjc-arc -Wall -Wextra -Werror
TGDeviceMask_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
