TARGET := iphone:clang:15.6
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# --- SpringBoard tweak: match + unlock only ---
TWEAK_NAME = FaceUnlock
FaceUnlock_FILES = Tweak.xm FacePrint.m
FaceUnlock_FRAMEWORKS = AVFoundation Vision UIKit CoreImage CoreGraphics
FaceUnlock_CFLAGS = -fobjc-arc

# --- companion app: enrollment / settings ---
APPLICATION_NAME = FaceUnlockSettings
FaceUnlockSettings_FILES = settings/main.m settings/FaceUnlockSettings.m FacePrint.m
FaceUnlockSettings_FRAMEWORKS = UIKit Foundation AVFoundation Vision CoreImage CoreGraphics
FaceUnlockSettings_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/application.mk

# theos generates a minimal Info.plist for the app; replace it with ours
# (NSCameraUsageDescription, scene manifest, icon) and add the app icon.
after-stage::
	@APPDIR=`find $(THEOS_STAGING_DIR) -name "FaceUnlockSettings.app" -type d | head -n 1`; \
	if [ -z "$$APPDIR" ]; then echo "ERROR: FaceUnlockSettings.app not found in staging"; exit 1; fi; \
	cp settings/Info.plist "$$APPDIR/Info.plist"; \
	cp settings/AppIcon60x60@2x.png "$$APPDIR/"; \
	echo "patched $$APPDIR"
