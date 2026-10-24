TARGET := iphone:clang:15.6
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# --- SpringBoard tweak: match + unlock only ---
# Vision / AVFoundation / CoreMedia / CoreVideo are WEAK-LINKED here and in fact
# end up with NO load command at all (nothing references their symbols strongly
# once every class lookup goes through NSClassFromString). That means dyld loads
# nothing framework-related when injecting into SpringBoard — a framework that
# fails to load can no longer kill the process at load time (a Safe Mode cause in
# v1.0.x / v1.1.x). The frameworks are dlopen()ed at runtime from setUp() instead,
# after SpringBoard is initialized; failure there just disables the feature.
TWEAK_NAME = FaceUnlock
FaceUnlock_FILES = Tweak.xm FacePrint.m
FaceUnlock_FRAMEWORKS = UIKit CoreImage CoreGraphics
FaceUnlock_WEAK_FRAMEWORKS = AVFoundation Vision CoreMedia CoreVideo
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
