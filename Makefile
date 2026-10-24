TARGET := iphone:clang:15.6
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = FaceUnlock

FaceUnlock_FILES = Tweak.xm
FaceUnlock_FRAMEWORKS = AVFoundation Vision UIKit CoreImage CoreGraphics
FaceUnlock_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
