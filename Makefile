TARGET := iphone:clang:15.6
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# --- SpringBoard tweak: match + unlock only ---
# Vision and AVFoundation are WEAK-LINKED here: SpringBoard does not normally
# load them, and a hard link makes dyld kill the process if either framework
# fails to load inside SpringBoard (that was a Safe Mode cause). With the weak
# link + the NSClassFromString guards in Tweak.xm / FacePrint.m, a missing
# framework logs one line and disables the feature instead.
TWEAK_NAME = FaceUnlock
FaceUnlock_FILES = Tweak.xm FacePrint.m
FaceUnlock_FRAMEWORKS = UIKit CoreImage CoreGraphics
FaceUnlock_WEAK_FRAMEWORKS = AVFoundation Vision
FaceUnlock_CFLAGS = -fobjc-arc

# --- companion app: enrollment / settings ---
# The app is a normal process: hard links are correct there.
APPLICATION_NAME = FaceUnlockSettings
FaceUnlockSettings_FILES = settings/main.m settings/FaceUnlockSettings.m FacePrint.m
FaceUnlockSettings_FRAMEWORKS = UIKit Foundation AVFoundation Vision CoreImage CoreGraphics
FaceUnlockSettings_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/application.mk

# theos generates a minimal Info.plist for the app; replace it with ours
# (NSCameraUsageDescription, icon) and add the app icon.
after-stage::
	@APPDIR=`find $(THEOS_STAGING_DIR) -name "FaceUnlockSettings.app" -type d | head -n 1`; \
	if [ -z "$$APPDIR" ]; then echo "ERROR: FaceUnlockSettings.app not found in staging"; exit 1; fi; \
	cp settings/Info.plist "$$APPDIR/Info.plist"; \
	cp settings/AppIcon60x60@2x.png "$$APPDIR/"; \
	echo "patched $$APPDIR"
