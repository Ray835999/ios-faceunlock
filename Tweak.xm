//
//  FaceUnlock — camera-based face unlock for Touch ID devices
//  Target: iPhone 6s / iOS 15.8.x / rootless palera1n (Dopamine)
//
//  Design (all private API access is runtime-guarded; nothing SpringBoard-
//  related runs at load time):
//   1. Lock screen appears -> start the front camera and run Vision face
//      detection + feature print per frame (~3 fps) for a bounded window.
//   2. Enrollment lives in the companion app (FaceUnlockSettings): it writes
//      templates.plist and posts a Darwin notification so this tweak reloads
//      the templates immediately.
//   3. Match: min distance vs stored prints < threshold for 2 consecutive
//      frames -> setAuthenticated:YES then
//      SBLockScreenManager lockScreenViewControllerRequestsUnlock
//      (the same unlock-completion call FastUnlockX uses).
//
//  Crash-safety rules (Safe Mode post-mortem, v1.0.1 + v1.2.x):
//   - %ctor must NOT touch SpringBoard singletons, register notifications, or
//     call any API beyond a single NSLog. Tweaks are loaded at dyld time,
//     before SpringBoard is initialized; setUp() is deferred to the first
//     lock-screen appearance.
//   - Vision / AVFoundation / CoreMedia / CoreVideo are WEAK-LINKED and end up
//     with NO load command in this dylib at all, so dyld loads nothing
//     framework-related when injecting into SpringBoard. They are dlopen()ed at
//     runtime from setUp() (after SpringBoard is initialized) and every class
//     is resolved with NSClassFromString / every extern constant NULL-checked,
//     so a framework that fails to load logs one line and disables the feature
//     instead of killing the process.
//   - Every hook body and the entire capture pipeline is wrapped in
//     @try/@catch: an NSException escaping into SpringBoard is a crash.
//   - AVCaptureSession is owned by the capture queue; the main thread only
//     flips BOOL gates. A session generation counter prevents a stale
//     teardown from clearing a freshly started session's gates.
//   - Templates are mutated on the capture queue and read on the main thread,
//     so every access is @synchronized.
//   - Kill switch: create /var/jb/var/mobile/Library/FaceUnlock/DISABLED to
//     stop all hook activity without uninstalling.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>

#import "FacePrint.h"

#define FU_LOG(fmt, ...) NSLog(@"[FaceUnlock] " fmt, ##__VA_ARGS__)

static NSString *const kPrefsAppID = @"com.ray835999.faceunlock";

// Darwin notification posted by FaceUnlockSettings after enrollment changes.
static NSString *const kTemplatesChangedNotify =
    @"com.ray835999.faceunlock.templates-changed";

// Touch this file to disable the tweak at runtime (no uninstall needed).
static NSString *const kKillSwitchPath =
    @"/var/jb/var/mobile/Library/FaceUnlock/DISABLED";

static const NSTimeInterval kScanWindow        = 12.0;  // auto-stop without a match
static const NSTimeInterval kAnalysisInterval  = 0.35;  // ~3 fps
static const NSTimeInterval kLogInterval       = 2.0;
static const NSUInteger    kRequiredConsecutive = 2;

// ---------------------------------------------------------------------------
// prefs (plist at /var/jb/var/mobile/Library/Preferences/<appid>.plist)
// ---------------------------------------------------------------------------
static BOOL FUPrefBool(NSString *key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kPrefsAppID);
    if (!v) return def;
    BOOL b = def;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID() || t == CFNumberGetTypeID()) b = [(__bridge NSNumber *)v boolValue];
    CFRelease(v);
    return b;
}
static float FUPrefFloat(NSString *key, float def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kPrefsAppID);
    if (!v) return def;
    float f = def;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID() || t == CFNumberGetTypeID()) f = [(__bridge NSNumber *)v floatValue];
    CFRelease(v);
    return f;
}

// AVFoundation classes, resolved at runtime (weak framework in the tweak).
static Class FUAV(NSString *name) { return NSClassFromString(name); }

// The tweak does NOT carry load commands for these frameworks (weak link, no
// strong symbol references), so dyld loads nothing framework-related at
// injection time. They are dlopen()ed at runtime instead — after SpringBoard is
// initialized — so a broken/missing framework disables the feature with a log
// line instead of killing the process.
static void FULoadOptionalFrameworks(void) {
    @autoreleasepool {
        void *cm = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
        FU_LOG("dlopen CoreMedia: %s", cm ? "ok" : (dlerror() ?: "failed"));
        void *av = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
        FU_LOG("dlopen AVFoundation: %s", av ? "ok" : (dlerror() ?: "failed"));
        void *vi = dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY);
        FU_LOG("dlopen Vision: %s", vi ? "ok" : (dlerror() ?: "failed"));
    }
}

// True when AVFoundation + the constants the capture path needs are present.
// (Weak-linked extern NSString constants are NULL when the framework is absent.)
static BOOL FUAVFoundationAvailable(void) {
    return (FUAV(@"AVCaptureDevice") != nil
         && FUAV(@"AVCaptureDeviceInput") != nil
         && FUAV(@"AVCaptureSession") != nil
         && FUAV(@"AVCaptureVideoDataOutput") != nil
         && FUAV(@"AVCaptureConnection") != nil
         && FUAV(@"AVCaptureDeviceDiscoverySession") != nil
         && AVCaptureDeviceTypeBuiltInWideAngleCamera != NULL
         && AVMediaTypeVideo != NULL
         && AVCaptureSessionPreset640x480 != NULL
         && kCVPixelBufferPixelFormatTypeKey != NULL);
}

// ---------------------------------------------------------------------------
// manager
// ---------------------------------------------------------------------------
@interface FaceUnlockManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, weak)   id       dashBoardVC;
@property (nonatomic, assign) BOOL     faceUnlockInProgress;
@property (nonatomic, assign) BOOL     deviceLocked;

+ (instancetype)sharedManager;
- (void)setUp;
- (void)reloadTemplates;
- (void)lockScreenDidAppear;
- (void)noteDeviceLocked;
- (void)completeFaceUnlock;

- (BOOL)enabled;
- (float)threshold;

@end

@implementation FaceUnlockManager {
    // main-thread state
    BOOL               _sessionActive;   // a scan session is armed
    BOOL               _analyzing;       // frames are being processed (gate)
    NSUInteger         _sessionGen;      // generation of the armed session

    // capture-queue-only state
    dispatch_queue_t   _captureQueue;
    AVCaptureSession  *_session;
    NSUInteger         _runningGen;      // generation of the live session
    NSMutableArray    *_templates;
    NSDate            *_lastAnalysis;
    NSDate            *_scanDeadline;
    NSTimeInterval     _lastLog;
    NSUInteger         _consecutive;
    float              _sessionBest;

    // shared state
    id                 _templatesLock;
    BOOL               _setUpDone;
    BOOL               _passcodeSet;
    BOOL               _notifyRegistered;
}

+ (instancetype)sharedManager {
    static FaceUnlockManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [FaceUnlockManager new]; });
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _captureQueue  = dispatch_queue_create("com.ray835999.faceunlock.capture", DISPATCH_QUEUE_SERIAL);
        _templates     = [NSMutableArray array];
        _templatesLock = [NSObject new];
        _passcodeSet   = YES;
    }
    return self;
}

static BOOL FUKillSwitchEngaged(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:kKillSwitchPath];
}

// Deferred from %ctor on purpose: this touches SpringBoard singletons and
// Darwin notifications, and is only safe once SpringBoard is fully initialized
// (first lock-screen appearance).
- (void)setUp {
    if (_setUpDone) return;
    _setUpDone = YES;
    [self reloadTemplates];

    // hot-reload templates when FaceUnlockSettings changes enrollment.
    // Registered here (not in %ctor): notify_register_dispatch is only safe
    // after the host process is initialized.
    if (!_notifyRegistered) {
        _notifyRegistered = YES;
        notify_register_dispatch(kTemplatesChangedNotify.UTF8String, NULL,
                                 dispatch_get_main_queue(), ^(int token) {
            [[FaceUnlockManager sharedManager] reloadTemplates];
        });
    }

    // Runtime-load the optional frameworks (they are NOT linked into this
    // dylib, so nothing framework-related can fail at dyld load time).
    FULoadOptionalFrameworks();

    BOOL passcode = YES;
    id lockMgr = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (lockMgr && [lockMgr respondsToSelector:@selector(isPasscodeSet)]) {
        passcode = ((BOOL (*)(id, SEL))objc_msgSend)(lockMgr, @selector(isPasscodeSet));
    }
    _passcodeSet = passcode;
    NSUInteger enrolled = 0;
    @synchronized (_templatesLock) { enrolled = _templates.count; }
    FU_LOG("loaded: enabled=%d threshold=%.3f enrolled=%lu passcodeSet=%d vision=%d avfoundation=%d",
           FUPrefBool(@"Enabled", YES), FUPrefFloat(@"Threshold", 0.5),
           (unsigned long)enrolled, passcode,
           [FacePrint visionAvailable], FUAVFoundationAvailable());
    if (!FUPrefBool(@"Enabled", YES)) FU_LOG("tweak disabled via prefs (Enabled=NO)");
    if (![FacePrint visionAvailable])   FU_LOG("Vision unavailable in this process - face unlock disabled");
    if (!FUAVFoundationAvailable())     FU_LOG("AVFoundation unavailable in this process - face unlock disabled");
    if (!passcode) FU_LOG("no lock screen passcode set - face unlock needs a passcode (same as Vizage)");
    if (enrolled == 0) FU_LOG("no faceprints yet - enroll in the FaceUnlockSettings app");
}

- (void)reloadTemplates {
    NSArray *t = [FacePrint loadTemplates];
    @synchronized (_templatesLock) {
        [_templates setArray:t];
    }
    FU_LOG("templates reloaded: %lu", (unsigned long)t.count);
}

#pragma mark - prefs
- (BOOL)enabled    { return FUPrefBool(@"Enabled", YES); }
- (float)threshold { return FUPrefFloat(@"Threshold", 0.5); }

#pragma mark - scan session lifecycle
// main thread: arm/disarm gates only; the session itself lives on _captureQueue
- (void)startScanning {
    if (_sessionActive) return;
    if (FUKillSwitchEngaged())      { FU_LOG("startScanning: DISABLED kill switch present"); return; }
    if (!self.enabled)              { FU_LOG("startScanning: disabled by prefs"); return; }
    if (!_passcodeSet)              { return; }   // nothing to unlock without a passcode
    if (![FacePrint visionAvailable])   { return; }
    if (!FUAVFoundationAvailable())     { return; }

    NSUInteger enrolled = 0;
    @synchronized (_templatesLock) { enrolled = _templates.count; }
    if (enrolled == 0) {
        FU_LOG("startScanning: no faceprints yet - enroll in the FaceUnlockSettings app");
        return;
    }

    _sessionGen++;
    _sessionActive = YES;
    _analyzing     = YES;
    NSUInteger gen = _sessionGen;
    dispatch_async(_captureQueue, ^{
        @autoreleasepool { [self setupAndRunSessionGen:gen]; }
    });
}

// any thread: flip the frame gate now, tear the session down on its own queue
- (void)stopScanning {
    _analyzing = NO;
    if (!_sessionActive) return;
    _sessionActive = NO;
    dispatch_async(_captureQueue, ^{
        @autoreleasepool { [self finishSessionOnQueue]; }
    });
}

// capture queue only: create + start the session (or log why we cannot)
- (void)setupAndRunSessionGen:(NSUInteger)gen {
    @try {
        if (!FUAVFoundationAvailable()) {
            FU_LOG("startScanning: AVFoundation unavailable - face unlock disabled");
            [self finishSessionOnQueue];
            return;
        }

        // Log the camera authorization state: in a process without camera
        // entitlement (e.g. SpringBoard) this shows up as notDetermined and
        // the session will simply never deliver frames.
        @try {
            AVAuthorizationStatus st =
                ((AVAuthorizationStatus (*)(id, SEL, id))objc_msgSend)(
                    FUAV(@"AVCaptureDevice"), @selector(authorizationStatusForMediaType:),
                    (id)AVMediaTypeVideo);
            FU_LOG("camera authorization status: %ld", (long)st);
        } @catch (NSException *ex) {
            FU_LOG("camera authorization probe failed: %@", ex.reason);
        }

        AVCaptureDeviceDiscoverySession *disc =
            [(id)FUAV(@"AVCaptureDeviceDiscoverySession")
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                      mediaType:AVMediaTypeVideo
                                       position:AVCaptureDevicePositionFront];
        AVCaptureDevice *cam = disc.devices.firstObject;
        if (!cam) { FU_LOG("startScanning: no front camera found"); [self finishSessionOnQueue]; return; }

        NSError *err = nil;
        AVCaptureDeviceInput *input =
            [(id)FUAV(@"AVCaptureDeviceInput") deviceInputWithDevice:cam error:&err];
        if (!input) {
            FU_LOG("startScanning: camera input error: %@", err.localizedDescription ?: @"?");
            [self finishSessionOnQueue];
            return;
        }

        AVCaptureSession *session = [(id)FUAV(@"AVCaptureSession") new];
        session.sessionPreset = AVCaptureSessionPreset640x480;
        if (![session canAddInput:input]) { FU_LOG("startScanning: cannot add camera input"); [self finishSessionOnQueue]; return; }
        [session addInput:input];

        AVCaptureVideoDataOutput *out = [(id)FUAV(@"AVCaptureVideoDataOutput") new];
        out.alwaysDiscardsLateVideoFrames = YES;
        out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
        [out setSampleBufferDelegate:self queue:_captureQueue];
        if (![session canAddOutput:out]) { FU_LOG("startScanning: cannot add video output"); [self finishSessionOnQueue]; return; }
        [session addOutput:out];
        AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
        if (conn.supportsVideoOrientation) conn.videoOrientation = AVCaptureVideoOrientationPortrait;

        _consecutive  = 0;
        _sessionBest  = INFINITY;
        _scanDeadline = [NSDate dateWithTimeIntervalSinceNow:kScanWindow];
        _runningGen   = gen;
        _session      = session;
        [session startRunning];
        FU_LOG("scanning started (MATCH mode, window=%.0fs)", kScanWindow);
    } @catch (NSException *ex) {
        FU_LOG("session setup exception: %@", ex.reason);
        [self finishSessionOnQueue];
    }
}

// capture queue only: stop + drop the live session, then clear the main-thread
// gates — but only if the session we just tore down is still the armed one.
- (void)finishSessionOnQueue {
    if (_sessionBest != INFINITY) {
        FU_LOG("scan session best distance=%.3f (threshold=%.3f)", _sessionBest, self.threshold);
        _sessionBest = INFINITY;
    }
    if (_session) {
        [_session stopRunning];
        _session = nil;
    }
    NSUInteger gen = _runningGen;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_sessionGen == gen) {
            self->_sessionActive = NO;
            self->_analyzing     = NO;
        }
    });
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
      fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        @try {
            if (!_analyzing || !_session) return;
            NSDate *now = [NSDate date];
            if (_lastAnalysis && [now timeIntervalSinceDate:_lastAnalysis] < kAnalysisInterval) return;
            _lastAnalysis = now;
            if ([now timeIntervalSinceDate:_scanDeadline] > 0) {
                [self stopScanning];
                return;
            }

            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pb) return;

            VNFaceObservation *face = [FacePrint detectFaceInPixelBuffer:pb qualityGate:YES];
            if (!face) return;

            VNFeaturePrintObservation *print =
                [FacePrint observationForFace:face pixelBuffer:pb logPrefix:@"tweak"];
            if (!print) return;

            NSArray *snapshot = nil;
            @synchronized (_templatesLock) {
                snapshot = [_templates copy];   // copy under the lock: the array
            }                                    // is mutated on this same queue
            if (snapshot.count == 0) return;

            float best = INFINITY;
            for (NSDictionary *rec in snapshot) {
                float d = [FacePrint distanceFromTemplate:rec toPrint:print];
                if (d < best) best = d;
            }
            if (best == INFINITY) return;
            if (best < _sessionBest) _sessionBest = best;
            [self throttledLog:[NSString stringWithFormat:@"distance=%.3f threshold=%.3f", best, self.threshold]];

            if (best < self.threshold) {
                _consecutive++;
                if (_consecutive >= kRequiredConsecutive) {
                    _consecutive = 0;
                    [self requestFaceUnlock:best];
                }
            } else {
                _consecutive = 0;
            }
        } @catch (NSException *ex) {
            FU_LOG("capture exception: %@", ex.reason);
            [self stopScanning];
        }
    }
}

- (void)throttledLog:(NSString *)msg {
    NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate];
    if (t - _lastLog < kLogInterval) return;
    _lastLog = t;
    FU_LOG("%@", msg);
}

#pragma mark - unlock
- (void)requestFaceUnlock:(float)distance {
    if (self.faceUnlockInProgress) return;
    self.faceUnlockInProgress = YES;
    [self stopScanning];
    FU_LOG("MATCH distance=%.3f - requesting unlock", distance);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            id vc = self.dashBoardVC;
            if (vc && [vc respondsToSelector:@selector(setAuthenticated:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, @selector(setAuthenticated:), YES);
            } else {
                FU_LOG("setAuthenticated: unavailable - using unlock-request fallback");
                [self completeFaceUnlock];
            }
            // safety net: if the hook never completes the unlock, force it shortly after
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    if (self.faceUnlockInProgress) {
                        FU_LOG("safety net: forcing unlock request");
                        [self completeFaceUnlock];
                    }
                }
            });
        }
    });
}

// Mirrors FastUnlockX (CP Digital Darkroom, MIT): after authentication the lock
// screen asks SBLockScreenManager to complete the unlock. Their tweak guards the
// call with !hasContent on the combined list; we do the same via KVC.
- (void)completeFaceUnlock {
    self.faceUnlockInProgress = NO;
    id lockMgr = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    SEL sel = @selector(lockScreenViewControllerRequestsUnlock);
    if (!lockMgr || ![lockMgr respondsToSelector:sel]) {
        FU_LOG("SBLockScreenManager / lockScreenViewControllerRequestsUnlock unavailable");
        return;
    }
    BOOL hasContent = NO;
    @try {
        id vc   = self.dashBoardVC;
        id page = [vc valueForKey:@"mainPageContentViewController"];
        id list = [page valueForKey:@"combinedListViewController"];
        NSNumber *hc = [list valueForKey:@"hasContent"];
        hasContent = [hc isKindOfClass:[NSNumber class]] ? hc.boolValue : NO;
    } @catch (NSException *ex) {
        FU_LOG("hasContent probe failed: %@", ex.reason);
    }
    if (hasContent) {
        FU_LOG("unlock request deferred: lock screen has notification content");
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(lockMgr, sel);
    FU_LOG("lockScreenViewControllerRequestsUnlock sent");
}

#pragma mark - state transitions
- (void)lockScreenDidAppear {
    self.deviceLocked = YES;
    if (FUKillSwitchEngaged()) return;
    if (!self.enabled) return;
    if (!_setUpDone) [self setUp];
    [self startScanning];
}

- (void)noteDeviceLocked {
    self.deviceLocked = YES;
    if (FUKillSwitchEngaged()) return;
    if (!self.enabled) return;
    if (!_setUpDone) [self setUp];
    [self startScanning];
}

@end

// ---------------------------------------------------------------------------
// hooks
// ---------------------------------------------------------------------------
static inline FaceUnlockManager *FUMgr(void) { return [FaceUnlockManager sharedManager]; }

%hook SBDashBoardViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        @try {
            if (FUKillSwitchEngaged()) return;
            FUMgr().dashBoardVC = self;
            [FUMgr() lockScreenDidAppear];
        } @catch (NSException *ex) {
            FU_LOG("viewDidAppear hook exception: %@", ex.reason);
        }
    }
}

- (void)setAuthenticated:(BOOL)authenticated {
    BOOL ours = NO;
    @autoreleasepool {
        @try {
            ours = FUMgr().faceUnlockInProgress;
            %orig;
            if (authenticated) {
                if (ours) [FUMgr() completeFaceUnlock];   // finish the unlock we requested
            } else {
                [FUMgr() noteDeviceLocked];
            }
        } @catch (NSException *ex) {
            FU_LOG("setAuthenticated hook exception: %@", ex.reason);
        }
    }
}

%end

// Load-time rule: NOTHING but a single log line may run here. Tweaks are
// injected at dyld time, before SpringBoard is initialized — even
// +sharedInstance on a SpringBoard singleton crashes the process (Safe Mode),
// and notify_register_dispatch is deferred to setUp() for the same reason.
%ctor {
    FU_LOG("ctor: FaceUnlock loaded (dyld time, no SpringBoard API touched)");
}
