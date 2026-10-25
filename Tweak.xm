//
//  FaceUnlock 2.0.0 — camera face unlock for Touch ID devices
//  Target: iPhone 6s / iOS 15.8.x / rootless (Dopamine / palera1n)
//
//  ===========================================================================
//  WHY THIS IS A REWRITE (v1.x kept crashing SpringBoard or hanging the phone)
//  ===========================================================================
//  v1.x tried to be clever: a %ctor that "only logged", delayed setup, lazy
//  framework loading, a hook on the lock-screen view controller. Every one of
//  those was still a code path inside SpringBoard that could throw, block, or
//  race. The user-visible result was either Safe Mode or a phone that stopped
//  responding to touches (a hung SpringBoard looks exactly like "buttons don't
//  work").
//
//  v2.0.0 takes the opposite approach — assume this process is hostile:
//
//   1. BOOT-LOOP CIRCUIT BREAKER. %ctor increments a counter file. If the tweak
//      has been loaded 4+ times inside 120 s (i.e. SpringBoard is crash-looping
//      because of us), it writes the DISABLED kill switch and hooks NOTHING.
//      This is what makes "一会崩溃" self-healing: worst case one bad boot, then
//      the tweak disables itself instead of pushing the device into Safe Mode.
//
//   2. NO FRAMEWORK SYMBOLS AT ALL. Every AVFoundation / CoreVideo / Vision
//      constant is replaced by its literal value ("vide", "PixelFormatType",
//      0x42475241, ...). Nothing extern is referenced, so this dylib carries no
//      strong symbol references into frameworks that might not be loadable
//      inside SpringBoard, and nothing can be NULL at runtime.
//
//   3. LAZY EVERYTHING. %ctor does not touch SpringBoard, does not register
//      notifications, does not dlopen. Setup happens 3 s later on the main
//      queue, and the frameworks are only dlopen()ed the first time a scan is
//      actually needed.
//
//   4. NO-FRAME WATCHDOG. A capture session that never delivers frames is the
//      classic "phone is stuck" scenario. 3 s after start, if zero frames
//      arrived, the session is torn down on its own queue and the failure is
//      counted. Three failures in a row => auto-disable (kill switch), so the
//      phone can never be left holding a wedged camera session.
//
//   5. EVERY ESCAPE IS CONTAINED. Hook bodies, session setup, frame analysis,
//      unlock — each has @try/@catch and a bounded timeout.
//
//   6. TELEMETRY INSTEAD OF LOG SCRAPING. Everything observable is written to
//      status.plist, which the companion app displays on screen. The user never
//      has to run a console command to tell us what happened.
//
//  Everything SpringBoard-visible is guarded by FU_OK() kill switches.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <math.h>

#import "FacePrint.h"

// ---------------------------------------------------------------------------
// shared paths
// ---------------------------------------------------------------------------
#define FU_DIR @"/var/jb/var/mobile/Library/FaceUnlock"

static NSString *FUPath(NSString *name) {
    return [FU_DIR stringByAppendingPathComponent:name];
}

static void FULogAppend(NSString *msg) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:FU_DIR withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *p = FUPath(@"tweak.log");
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            if (at && [at fileSize] > 96 * 1024) { [fm removeItemAtPath:p error:nil]; at = nil; }
            if (!at) [fm createFileAtPath:p contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) return;
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg ?: @""];
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {
            // logging must never throw into the host
        }
    }
}

#define FU_LOG(fmt, ...) do { \
    NSString *_fu_m = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[FaceUnlock] %@", _fu_m); \
    FULogAppend(_fu_m); \
} while (0)

// ---------------------------------------------------------------------------
// telemetry (status.plist) — the app renders this on screen
// ---------------------------------------------------------------------------
static NSMutableDictionary *gStatus = nil;
static NSObject *gStatusLock = nil;
static NSTimeInterval gLastFlush = 0;

static void FUStatusFlush(BOOL force) {
    @try {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!force && now - gLastFlush < 1.0) return;
        gLastFlush = now;
        NSDictionary *snapshot = nil;
        @synchronized (gStatusLock) {
            NSMutableDictionary *d = [gStatus mutableCopy];
            d[@"updated"] = [NSDate date];
            d[@"updatedEpoch"] = @(now);
            snapshot = d;
        }
        [snapshot writeToFile:FUPath(@"status.plist") atomically:YES];
    } @catch (NSException *e) {
        // never throw
    }
}

static void FUStatusSet(NSString *key, id value) {
    @try {
        @synchronized (gStatusLock) {
            if (!gStatus) return;
            if (value) gStatus[key] = value;
            else        [gStatus removeObjectForKey:key];
        }
        FUStatusFlush(NO);
    } @catch (NSException *e) {
        // never throw
    }
}

static void FUStatusAdd(NSString *key, long long delta) {
    @try {
        @synchronized (gStatusLock) {
            if (!gStatus) return;
            long long v = [gStatus[key] longLongValue] + delta;
            gStatus[key] = @(v);
        }
        FUStatusFlush(NO);
    } @catch (NSException *e) {
        // never throw
    }
}

// ---------------------------------------------------------------------------
// kill switch + circuit breaker
// ---------------------------------------------------------------------------
static BOOL FUKillSwitch(void) {
    @try {
        return [[NSFileManager defaultManager] fileExistsAtPath:FUPath(@"DISABLED")];
    } @catch (NSException *e) { return YES; }
}

static void FUKillSwitchEngage(NSString *why) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:FU_DIR
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [why writeToFile:FUPath(@"DISABLED") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

// Returns YES when the tweak must stay completely inert this boot.
// Writes DISABLED when it detects a crash loop caused by us.
//
// Discriminator: a real SpringBoard crash loop reloads this dylib every 2-5 s,
// so 4 loads land inside a few seconds. A human doing manual resprings cannot
// reach 4 loads in 40 s (each respring alone takes longer). Using 120 s here
// would false-positive on "respring, look, respring again" testing.
static BOOL FUBootGuard(void) {
    @try {
        NSString *p = FUPath(@"boot.plist");
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        double first = [d[@"first"] doubleValue];
        int count = [d[@"count"] intValue];
        if (first <= 0 || (now - first) > 40.0) { first = now; count = 0; }
        count++;
        NSDictionary *out = @{ @"first": @(first), @"count": @(count), @"last": @(now) };
        [[NSFileManager defaultManager] createDirectoryAtPath:FU_DIR
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        [out writeToFile:p atomically:YES];
        if (count >= 4) {
            FUKillSwitchEngage(@"auto-disabled: tweak loaded 4 times within 40s (SpringBoard was crash-looping)\n"
                               @"delete this file / press 急停 then 重新启用 in the app to re-enable");
            return YES;
        }
        return NO;
    } @catch (NSException *e) {
        return YES;   // when in doubt, do nothing
    }
}

// ---------------------------------------------------------------------------
// framework availability (all runtime, zero extern symbols)
// ---------------------------------------------------------------------------
static Class FUClass(NSString *name) {
    @try { return NSClassFromString(name); } @catch (NSException *e) { return Nil; }
}

static BOOL gFrameworksTried = NO;
static BOOL gAVOK = NO;
static BOOL gVisionOK = NO;

static void FULoadFrameworksOnce(void) {
    if (gFrameworksTried) return;
    gFrameworksTried = YES;
    @try {
        void *av = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
        void *cv = dlopen("/System/Library/Frameworks/CoreVideo.framework/CoreVideo", RTLD_LAZY);
        void *vi = dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY);
        FU_LOG(@"dlopen AVFoundation=%s CoreVideo=%s Vision=%s",
               av ? "ok" : "FAIL", cv ? "ok" : "FAIL", vi ? "ok" : "FAIL");
        gAVOK = (FUClass(@"AVCaptureSession") != Nil &&
                 FUClass(@"AVCaptureDevice") != Nil &&
                 FUClass(@"AVCaptureDeviceInput") != Nil &&
                 FUClass(@"AVCaptureVideoDataOutput") != Nil &&
                 FUClass(@"AVCaptureVideoDataOutput") != Nil);
        gVisionOK = [FacePrint visionAvailable];
        FUStatusSet(@"avOK", @(gAVOK));
        FUStatusSet(@"visionOK", @(gVisionOK));
        if (!gAVOK)     FU_LOG(@"AVFoundation classes unavailable in SpringBoard");
        if (!gVisionOK) FU_LOG(@"Vision unavailable in SpringBoard");
    } @catch (NSException *e) {
        FU_LOG(@"framework load exception: %@", e.reason);
        gAVOK = NO; gVisionOK = NO;
    }
}

// ---------------------------------------------------------------------------
// manager
// ---------------------------------------------------------------------------
@interface FaceUnlockManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id lockScreenVC;
+ (instancetype)shared;
- (void)start;                     // main thread, 3 s after load
- (void)noteLockScreenAppeared:(id)vc;
- (void)noteDeviceLocked;
- (void)stopScanning;
@end

static const NSTimeInterval kScanWindow       = 10.0;
static const NSTimeInterval kAnalysisInterval = 0.30;
static const NSTimeInterval kNoFrameTimeout   = 3.0;
static const NSUInteger    kRequiredMatches   = 2;
static const int           kMaxCameraFailures = 3;

@implementation FaceUnlockManager {
    // main thread
    BOOL             _started;
    BOOL             _armed;
    NSUInteger       _gen;
    BOOL             _unlocking;

    // capture queue
    dispatch_queue_t _q;
    AVCaptureSession *_session;
    NSUInteger       _runGen;
    NSDate          *_lastAnalysis;
    NSDate          *_deadline;
    NSUInteger       _frames;
    NSUInteger       _consecutive;
    float            _best;
    long long        _failStreak;
    NSTimeInterval   _lastLog;

    // shared
    NSObject        *_tplLock;
    NSArray         *_templates;
    BOOL             _passcodeSet;
}

+ (instancetype)shared {
    static FaceUnlockManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStatusLock = [NSObject new];
        gStatus = [NSMutableDictionary dictionary];
        m = [FaceUnlockManager new];
    });
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q        = dispatch_queue_create("com.ray835999.faceunlock.capture", DISPATCH_QUEUE_SERIAL);
        _tplLock  = [NSObject new];
        _templates = @[];
        _best     = INFINITY;
    }
    return self;
}

#pragma mark - prefs
static BOOL FUPrefBool(NSString *key, BOOL def) {
    @try {
        CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key,
                                                        CFSTR("com.ray835999.faceunlock"));
        if (!v) return def;
        BOOL b = def;
        CFTypeID t = CFGetTypeID(v);
        if (t == CFBooleanGetTypeID() || t == CFNumberGetTypeID()) {
            b = [(__bridge NSNumber *)v boolValue];
        }
        CFRelease(v);
        return b;
    } @catch (NSException *e) { return def; }
}

static float FUPrefFloat(NSString *key, float def) {
    @try {
        CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key,
                                                        CFSTR("com.ray835999.faceunlock"));
        if (!v) return def;
        float f = def;
        CFTypeID t = CFGetTypeID(v);
        if (t == CFBooleanGetTypeID() || t == CFNumberGetTypeID()) {
            f = [(__bridge NSNumber *)v floatValue];
        }
        CFRelease(v);
        return f;
    } @catch (NSException *e) { return def; }
}

- (BOOL)enabled    { return FUPrefBool(@"Enabled", YES); }
- (float)threshold { return FUPrefFloat(@"Threshold", 0.55f); }

#pragma mark - startup (3 s after injection: SpringBoard is long since up)
- (void)start {
    if (_started) return;
    _started = YES;
    @try {
        NSDictionary *bundle = [[NSBundle mainBundle] infoDictionary];
        FUStatusSet(@"hostUp", @YES);
        FUStatusSet(@"version", @"2.0.0");
        FUStatusSet(@"hostVersion", bundle[@"CFBundleVersion"] ?: @"?");
        FUStatusSet(@"device", [[UIDevice currentDevice] systemVersion]);
        FUStatusSet(@"state", @"idle");

        BOOL killed = FUKillSwitch();
        FUStatusSet(@"killSwitch", @(killed));
        if (killed) {
            FU_LOG(@"kill switch present - standing down (delete %@/DISABLED to re-enable)",
                   FU_DIR);
            FUStatusSet(@"state", @"disabled (kill switch)");
            FUStatusFlush(YES);
            return;
        }

        id mgr = [FUClass(@"SBLockScreenManager") sharedInstance];
        if (mgr && [mgr respondsToSelector:@selector(isPasscodeSet)]) {
            _passcodeSet = ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isPasscodeSet));
        } else {
            _passcodeSet = YES;   // unknown: try anyway
        }
        FUStatusSet(@"passcodeSet", @(_passcodeSet));

        [self reloadTemplates];

        int token = 0;
        notify_register_dispatch("com.apple.springboard.lockcomplete", &token,
                                 dispatch_get_main_queue(), ^(int t) {
            @autoreleasepool {
                @try { [[FaceUnlockManager shared] noteDeviceLocked]; }
                @catch (NSException *e) { FU_LOG(@"lockcomplete handler: %@", e.reason); }
            }
        });
        FU_LOG(@"ready: enabled=%d threshold=%.2f templates=%lu passcodeSet=%d killSwitch=0",
               self.enabled, self.threshold, (unsigned long)[self templateCount], _passcodeSet);
        FUStatusSet(@"ready", @YES);
        FUStatusFlush(YES);
    } @catch (NSException *e) {
        FU_LOG(@"start exception: %@", e.reason);
    }
}

- (NSUInteger)templateCount {
    @synchronized (_tplLock) { return _templates.count; }
}

- (void)reloadTemplates {
    @try {
        NSArray *t = [FacePrint loadTemplates];
        @synchronized (_tplLock) { _templates = t ?: @[]; }
        FUStatusSet(@"templates", @([self templateCount]));
        FU_LOG(@"templates loaded: %lu", (unsigned long)[self templateCount]);
    } @catch (NSException *e) {
        FU_LOG(@"reloadTemplates: %@", e.reason);
    }
}

#pragma mark - triggers
- (void)noteLockScreenAppeared:(id)vc {
    @try {
        if (vc) self.lockScreenVC = vc;
        FUStatusSet(@"lockScreenVC", vc ? NSStringFromClass([vc class]) : @"none");
        [self noteDeviceLocked];
    } @catch (NSException *e) {
        FU_LOG(@"noteLockScreenAppeared: %@", e.reason);
    }
}

- (void)noteDeviceLocked {
    @try {
        if (FUKillSwitch()) { FUStatusSet(@"state", @"disabled (kill switch)"); return; }
        if (!self.enabled)  { FUStatusSet(@"state", @"disabled (pref)"); return; }
        // templates may have been enrolled/changed since the last lock
        if ([self templateCount] == 0) [self reloadTemplates];
        if ([self templateCount] == 0) {
            FUStatusSet(@"state", @"no templates - enroll in the FaceUnlock app");
            FU_LOG(@"locked, but no templates enrolled");
            return;
        }
        [self startScanning];
    } @catch (NSException *e) {
        FU_LOG(@"noteDeviceLocked: %@", e.reason);
    }
}

#pragma mark - scan lifecycle
- (void)startScanning {
    if (_armed) return;
    @try {
        // NOTE: no dlopen / framework probing here. This runs on the main thread
        // while the lock screen is animating in; loading Vision there costs a
        // visible hitch. All of it happens on the capture queue instead.
        if (_passcodeSet == NO) {
            FUStatusSet(@"state", @"no passcode - nothing to unlock");
            FU_LOG(@"no passcode set; face unlock is pointless");
            return;
        }
        if ([self templateCount] == 0) return;

        _gen++;
        _armed = YES;
        NSUInteger gen = _gen;
        FUStatusSet(@"state", @"scanning");
        FUStatusAdd(@"sessions", 1);
        FU_LOG(@"lock detected -> arming scan #%lu", (unsigned long)gen);

        dispatch_async(_q, ^{ @autoreleasepool { [self runSessionGen:gen]; } });
    } @catch (NSException *e) {
        FU_LOG(@"startScanning: %@", e.reason);
        FUStatusSet(@"state", @"error starting");
    }
}

- (void)stopScanning {
    if (!_armed) return;
    _armed = NO;
    dispatch_async(_q, ^{ @autoreleasepool { [self teardown]; } });
}

// capture queue only. Always clears _armed on the main thread (generation
// guarded) — otherwise one camera failure would silently disable every later
// lock for the rest of this SpringBoard session.
- (void)teardown {
    NSUInteger gen = _runGen;
    @try {
        if (_session) {
            [_session stopRunning];
            _session = nil;
        }
    } @catch (NSException *e) {
        FU_LOG(@"teardown: %@", e.reason);
    }
    _deadline = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_gen == gen) self->_armed = NO;
    });
}

// capture queue only
- (void)runSessionGen:(NSUInteger)gen {
    @autoreleasepool {
        @try {
            _runGen = gen;
            FULoadFrameworksOnce();
            if (!gAVOK || !gVisionOK) {
                FUStatusSet(@"state", gAVOK ? @"no Vision in SpringBoard"
                                            : @"no AVFoundation in SpringBoard");
                FU_LOG(@"frameworks unavailable - no scan this time");
                [self teardown];      // not a camera failure: do not count it
                return;
            }
            // authorization state (informational; never call requestAccess here:
            // an alert on top of the lock screen is exactly how v1.x hung)
            @try {
                AVAuthorizationStatus st =
                    ((AVAuthorizationStatus (*)(id, SEL, NSString *))objc_msgSend)(
                        FUClass(@"AVCaptureDevice"),
                        @selector(authorizationStatusForMediaType:), @"vide");
                FUStatusSet(@"cameraAuth", @(st));
                FU_LOG(@"camera authorization: %ld (0=notDetermined 1=restricted 2=denied 3=authorized)",
                       (long)st);
            } @catch (NSException *e) {}

            id discCls = FUClass(@"AVCaptureDeviceDiscoverySession");
            id disc = ((id (*)(id, SEL, NSArray *, NSString *, long))objc_msgSend)(
                discCls, @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                @[@"AVCaptureDeviceTypeBuiltInWideAngleCamera"], @"vide", 2L /* front */);
            NSArray *devices = disc ? [disc valueForKey:@"devices"] : nil;
            id cam = [devices isKindOfClass:[NSArray class]] ? [devices firstObject] : nil;
            if (!cam) { [self failWith:@"no front camera found"]; return; }

            NSError *err = nil;
            id input = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
                FUClass(@"AVCaptureDeviceInput"), @selector(deviceInputWithDevice:error:), cam, &err);
            if (!input) { [self failWith:[NSString stringWithFormat:@"camera input: %@",
                                         err.localizedDescription ?: @"?"]]; return; }

            AVCaptureSession *session = [(id)FUClass(@"AVCaptureSession") new];
            session.sessionPreset = @"AVCaptureSessionPreset640x480";
            if (![session canAddInput:input]) { [self failWith:@"cannot add camera input"]; return; }
            [session addInput:input];

            AVCaptureVideoDataOutput *out = [(id)FUClass(@"AVCaptureVideoDataOutput") new];
            out.alwaysDiscardsLateVideoFrames = YES;
            // literal "PixelFormatType" / 'BGRA' instead of the CoreVideo externs
            out.videoSettings = @{ @"PixelFormatType": @(0x42475241u) };
            [out setSampleBufferDelegate:self queue:_q];
            if (![session canAddOutput:out]) { [self failWith:@"cannot add video output"]; return; }
            [session addOutput:out];

            @try {
                AVCaptureConnection *conn = [out connectionWithMediaType:@"vide"];
                if (conn && conn.supportsVideoOrientation) {
                    conn.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
            } @catch (NSException *e) {}

            _frames      = 0;
            _consecutive = 0;
            _best        = INFINITY;
            _lastAnalysis = nil;
            _deadline    = [NSDate dateWithTimeIntervalSinceNow:kScanWindow];
            _session     = session;

            [session startRunning];
            FU_LOG(@"session started (gen %lu, window %.0fs)", (unsigned long)gen, kScanWindow);

            // watchdog: a session that never delivers frames is the classic
            // "phone is stuck holding the camera" case
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kNoFrameTimeout * NSEC_PER_SEC)),
                           _q, ^{
                @autoreleasepool {
                    if (gen != self->_runGen) return;
                    if (self->_frames > 0) return;
                    FU_LOG(@"WATCHDOG: 0 frames in %.0fs - tearing the session down", kNoFrameTimeout);
                    FUStatusSet(@"state", @"no frames (camera not delivering)");
                    [self teardown];
                    [self countCameraFailure];
                }
            });
        } @catch (NSException *e) {
            FU_LOG(@"runSession exception: %@", e.reason);
            [self failWith:[NSString stringWithFormat:@"session: %@", e.reason ?: @"?"]];
        }
    }
}

// capture queue only
- (void)failWith:(NSString *)why {
    FU_LOG(@"camera failure: %@", why);
    FUStatusSet(@"lastError", why);
    FUStatusSet(@"state", why);
    [self teardown];
    [self countCameraFailure];
}

// capture queue only
- (void)countCameraFailure {
    _failStreak++;
    FUStatusSet(@"cameraFailures", @(_failStreak));
    if (_failStreak >= kMaxCameraFailures) {
        FU_LOG(@"camera failed %d times in a row - auto-disabling so the phone stays usable",
               kMaxCameraFailures);
        FUKillSwitchEngage(@"auto-disabled: the camera could not be started inside SpringBoard "
                           @"(SpringBoard likely has no camera permission).\n"
                           @"Open the FaceUnlock app and press 重新启用 after checking.");
        FUStatusSet(@"killSwitch", @YES);
        FUStatusSet(@"state", @"auto-disabled (camera unavailable in SpringBoard)");
        FUStatusFlush(YES);
    }
}

#pragma mark - frames
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        @try {
            _frames++;
            if (_frames == 1) {
                FU_LOG(@"first frame received - camera is live in SpringBoard");
                FUStatusSet(@"state", @"scanning (frames arriving)");
                FUStatusAdd(@"frameSessions", 1);
            }
            if (!_armed || !_session) return;

            NSDate *now = [NSDate date];
            if (_lastAnalysis && [now timeIntervalSinceDate:_lastAnalysis] < kAnalysisInterval) return;
            _lastAnalysis = now;
            if (_deadline && [now timeIntervalSinceDate:_deadline] > 0) {
                FU_LOG(@"scan window expired (best=%.3f)", _best);
                [self stopScanning];
                FUStatusSet(@"state", @"idle (window expired)");
                return;
            }

            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pb) return;

            VNFaceObservation *face = [FacePrint detectFaceInPixelBuffer:pb qualityGate:YES];
            if (!face) return;
            FUStatusAdd(@"faces", 1);
            FUStatusSet(@"orientation", [FacePrint orientationName:[FacePrint workingOrientation]]);

            VNFeaturePrintObservation *print =
                [FacePrint observationForFace:face pixelBuffer:pb logPrefix:@"tweak"];
            if (!print) return;

            NSArray *snapshot = nil;
            @synchronized (_tplLock) { snapshot = _templates; }
            if (snapshot.count == 0) return;

            float best = INFINITY;
            for (NSDictionary *rec in snapshot) {
                float d = [FacePrint distanceFromTemplate:rec toPrint:print];
                if (d < best) best = d;
            }
            if (!isfinite(best)) return;
            if (best < _best) _best = best;
            FUStatusSet(@"lastDistance", @(best));

            NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate];
            if (t - _lastLog > 1.5) {
                _lastLog = t;
                FU_LOG(@"distance=%.3f (threshold=%.2f)", best, self.threshold);
            }

            if (best < self.threshold) {
                _consecutive++;
                if (_consecutive >= kRequiredMatches) {
                    _consecutive = 0;
                    [self requestUnlock:best];
                }
            } else {
                _consecutive = 0;
            }
        } @catch (NSException *e) {
            FU_LOG(@"frame exception: %@", e.reason);
            [self stopScanning];
        }
    }
}

#pragma mark - unlock
- (void)requestUnlock:(float)distance {
    if (_unlocking) return;
    _unlocking = YES;
    FU_LOG(@"MATCH (distance=%.3f) - unlocking", distance);
    FUStatusSet(@"lastMatch", @(distance));
    FUStatusAdd(@"matches", 1);
    [self stopScanning];
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool { [self performUnlockChain]; }
    });
}

// Try every known unlock route in order and record which one was used, so the
// next iteration is driven by evidence instead of guesses.
- (void)performUnlockChain {
    @try {
        NSMutableArray *log = [NSMutableArray array];
        id mgr = [FUClass(@"SBLockScreenManager") sharedInstance];
        if (!mgr) {
            FU_LOG(@"SBLockScreenManager unavailable");
            FUStatusSet(@"unlockPath", @"no SBLockScreenManager");
            _unlocking = NO;
            return;
        }

        // candidate lock-screen view controllers
        NSMutableArray *cands = [NSMutableArray array];
        if (self.lockScreenVC) [cands addObject:self.lockScreenVC];
        for (NSString *key in @[@"lockScreenViewController", @"_lockScreenViewController"]) {
            @try {
                id v = [mgr valueForKey:key];
                if (v && ![cands containsObject:v]) [cands addObject:v];
            } @catch (NSException *e) {}
        }
        // NB: deliberately no UIApplication.windows here. It is deprecated in the
        // iOS 15 SDK and theos builds with -Werror; KVC on SBLockScreenManager plus
        // the hooked controller already give us every candidate we need.

        // route 1: setAuthenticated:YES on whatever implements it
        for (id c in cands) {
            if (![c respondsToSelector:NSSelectorFromString(@"setAuthenticated:")]) continue;
            @try {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(c, NSSelectorFromString(@"setAuthenticated:"), YES);
                [log addObject:[NSString stringWithFormat:@"setAuthenticated on %@", NSStringFromClass([c class])]];
                break;
            } @catch (NSException *e) {
                [log addObject:[NSString stringWithFormat:@"setAuthenticated threw on %@",
                                NSStringFromClass([c class])]];
            }
        }

        // route 2: unlockUIFromSource:withOptions: (iOS 13+)
        SEL s2 = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
        if ([mgr respondsToSelector:s2]) {
            @try {
                ((void (*)(id, SEL, long, id))objc_msgSend)(mgr, s2, 0L, nil);
                [log addObject:@"unlockUIFromSource"];
            } @catch (NSException *e) {
                [log addObject:@"unlockUIFromSource threw"];
            }
        }

        // route 3: the call FastUnlockX uses to complete the unlock
        SEL s3 = NSSelectorFromString(@"lockScreenViewControllerRequestsUnlock");
        if ([mgr respondsToSelector:s3]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(mgr, s3);
                [log addObject:@"requestsUnlock"];
            } @catch (NSException *e) {
                [log addObject:@"requestsUnlock threw"];
            }
        }

        NSString *path = log.count ? [log componentsJoinedByString:@" + "] : @"no route available";
        FU_LOG(@"unlock routes: %@", path);
        FUStatusSet(@"unlockPath", path);

        // did it actually work?
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                BOOL stillLocked = NO;
                @try {
                    id m = [FUClass(@"SBLockScreenManager") sharedInstance];
                    if ([m respondsToSelector:NSSelectorFromString(@"isLockScreenVisible")]) {
                        stillLocked = ((BOOL (*)(id, SEL))objc_msgSend)(
                            m, NSSelectorFromString(@"isLockScreenVisible"));
                    }
                } @catch (NSException *e) {}
                FUStatusSet(@"stillLockedAfterUnlock", @(stillLocked));
                FU_LOG(@"post-unlock check: stillLocked=%d", stillLocked);
                FUStatusFlush(YES);
                self->_unlocking = NO;
            }
        });
    } @catch (NSException *e) {
        FU_LOG(@"unlock chain exception: %@", e.reason);
        _unlocking = NO;
    }
}

@end

// ---------------------------------------------------------------------------
// hooks (the only SpringBoard interaction; each body is fully contained)
// ---------------------------------------------------------------------------
%group FUCoverSheet
%hook CSCoverSheetViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        @try { [[FaceUnlockManager shared] noteLockScreenAppeared:self]; }
        @catch (NSException *e) { FU_LOG(@"coverSheet hook: %@", e.reason); }
    }
}
%end
%end

%group FUDashBoard
%hook SBDashBoardViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        @try { [[FaceUnlockManager shared] noteLockScreenAppeared:self]; }
        @catch (NSException *e) { FU_LOG(@"dashBoard hook: %@", e.reason); }
    }
}
%end
%end

%ctor {
    @autoreleasepool {
        // Nothing here may touch SpringBoard: this runs at dyld time, before the
        // host process is initialized.
        NSString *host = [[NSBundle mainBundle] bundleIdentifier];
        if (![host isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[FaceUnlock] ctor: host %@ is not SpringBoard - inert", host);
            return;
        }
        if (FUBootGuard()) {
            NSLog(@"[FaceUnlock] ctor: crash loop detected - tweak disabled, hooking nothing");
            // leave a trace the app can show even though the manager never starts
            @try {
                [@{ @"version": @"2.0.0",
                    @"state": @"disabled: crash loop detected at load (SpringBoard was restarting)",
                    @"updated": [NSDate date],
                    @"updatedEpoch": @([NSDate timeIntervalSinceReferenceDate]),
                    @"killSwitch": @YES,
                    @"hostUp": @NO }
                 writeToFile:FUPath(@"status.plist") atomically:YES];
            } @catch (NSException *e) {}
            return;
        }
        // hook only after the guard, so a crash-looping boot installs no hooks
        %init(FUCoverSheet);
        %init(FUDashBoard);
        NSLog(@"[FaceUnlock] ctor: loaded, setup deferred 3s");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                @try { [[FaceUnlockManager shared] start]; }
                @catch (NSException *e) { FU_LOG(@"deferred start: %@", e.reason); }
            }
        });
    }
}
