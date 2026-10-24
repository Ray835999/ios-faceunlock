//
//  FaceUnlock — camera-based face unlock for Touch ID devices
//  Target: iPhone 6s / iOS 15.8.x / rootless palera1n (Dopamine)
//
//  Design (all private API access is runtime-guarded; nothing SpringBoard-
//  related runs at load time):
//   1. Lock screen appears -> start the front camera and run Vision face
//      detection + feature print per frame (~3 fps) for a bounded window.
//   2. Enrollment: the first N lock/unlock events capture your faceprints.
//      No companion app needed.
//   3. Match: min distance vs stored prints < threshold for 2 consecutive
//      frames -> setAuthenticated:YES then
//      SBLockScreenManager lockScreenViewControllerRequestsUnlock
//      (the same unlock-completion call FastUnlockX uses).
//
//  Crash-safety rules (Safe Mode post-mortem):
//   - %ctor must NOT touch SpringBoard singletons. Tweaks are loaded at dyld
//     time, before SpringBoard is initialized; +[SBLockScreenManager
//     sharedInstance] there is a guaranteed crash. setUp() is deferred to the
//     first lock-screen appearance (main thread, SpringBoard fully up).
//   - Every hook body and the entire capture pipeline is wrapped in
//     @try/@catch: an NSException escaping into SpringBoard is a crash.
//   - UIKit is never touched off the main thread — the fallback normaliser is
//     CoreImage-only (CIImage + VNImageRequestHandler initWithCIImage:).
//   - AVCaptureSession is owned by the capture queue; the main thread only
//     flips BOOL gates. A session generation counter prevents a stale
//     teardown from clearing a freshly started session's gates.
//   - Templates are mutated on the capture queue and read on the main thread,
//     so every access is @synchronized.
//
//  Verified against iPhoneOS15.6.sdk headers:
//   - VNFeaturePrintObservation computeDistance:toFeaturePrintObservation:error:
//   - VNObservation : NSSecureCoding (prints are archivable)
//   - VNGenerateFaceFeaturePrintRequest is PRIVATE (not in the public SDK) ->
//     used via NSClassFromString, with a public crop + VNGenerateImageFeaturePrintRequest
//     fallback so the tweak still works if the private class disappears.
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

#define FU_LOG(fmt, ...) NSLog(@"[FaceUnlock] " fmt, ##__VA_ARGS__)

static NSString *const kPrefsAppID   = @"com.ray835999.faceunlock";
static NSString *const kTemplateDir  = @"/var/jb/var/mobile/Library/FaceUnlock";
static NSString *const kTemplateFile = @"/var/jb/var/mobile/Library/FaceUnlock/templates.plist";

static const NSTimeInterval kScanWindow         = 12.0;  // auto-stop without a match
static const NSTimeInterval kEnrollWindow       = 8.0;   // enrollment capture window
static const NSTimeInterval kAnalysisInterval   = 0.35;  // ~3 fps
static const NSTimeInterval kEnrollCooldown     = 1.5;   // min gap between samples
static const NSTimeInterval kLogInterval        = 2.0;
static const NSUInteger    kRequiredConsecutive = 2;
static const CGFloat       kNormalizeSize       = 256.0;

// ---------------------------------------------------------------------------
// prefs (plist at /var/jb/var/mobile/Library/Preferences/<appid>.plist)
// Type-checked: only CFBoolean/CFNumber are accepted, anything else -> default.
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
static NSInteger FUPrefInt(NSString *key, NSInteger def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kPrefsAppID);
    if (!v) return def;
    NSInteger i = def;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID() || t == CFNumberGetTypeID()) i = [(__bridge NSNumber *)v integerValue];
    CFRelease(v);
    return i;
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
- (void)lockScreenDidAppear;
- (void)noteDeviceLocked;
- (void)noteRealUnlock;
- (void)completeFaceUnlock;

// prefs (read live; defaults must make the tweak work out of the box)
- (BOOL)enabled;
- (float)threshold;
- (NSInteger)method;      // 0 auto, 1 faceprint only, 2 imageprint only
- (NSUInteger)enrollTarget;

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
    NSMutableArray    *_templates;       // @{ @"arch":NSData, @"vec":NSData, @"n":uint, @"t":uint }
    NSDate            *_lastAnalysis;
    NSDate            *_scanDeadline;
    NSDate            *_lastEnroll;
    NSTimeInterval     _lastLog;
    NSUInteger         _consecutive;
    BOOL               _enrollRequested;
    float              _sessionBest;

    // shared state
    id                 _templatesLock;
    BOOL               _setUpDone;
    BOOL               _passcodeSet;
}

+ (instancetype)sharedManager {
    static FaceUnlockManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [FaceUnlockManager new]; });
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _captureQueue = dispatch_queue_create("com.ray835999.faceunlock.capture", DISPATCH_QUEUE_SERIAL);
        _templates    = [NSMutableArray array];
        _templatesLock = [NSObject new];
        _passcodeSet  = YES;
    }
    return self;
}

// Deferred from %ctor on purpose: this touches SpringBoard singletons and is
// only safe once SpringBoard is fully initialized (first lock-screen appear).
- (void)setUp {
    if (_setUpDone) return;
    _setUpDone = YES;
    [self loadTemplates];
    BOOL passcode = YES;
    id lockMgr = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (lockMgr && [lockMgr respondsToSelector:@selector(isPasscodeSet)]) {
        passcode = ((BOOL (*)(id, SEL))objc_msgSend)(lockMgr, @selector(isPasscodeSet));
    }
    _passcodeSet = passcode;
    Class fp = NSClassFromString(@"VNGenerateFaceFeaturePrintRequest");
    NSUInteger enrolled = 0;
    @synchronized (_templatesLock) { enrolled = _templates.count; }
    FU_LOG("loaded: enabled=%d threshold=%.3f method=%ld enrolled=%lu passcodeSet=%d faceprintClass=%s",
           FUPrefBool(@"Enabled", YES), FUPrefFloat(@"Threshold", 0.5), (long)[self method],
           (unsigned long)enrolled, passcode, fp ? "yes" : "no->image-print fallback");
    if (!FUPrefBool(@"Enabled", YES)) FU_LOG("tweak disabled via prefs (Enabled=NO)");
    if (!passcode) FU_LOG("no lock screen passcode set - face unlock needs a passcode (same as Vizage)");
}

#pragma mark - prefs
- (BOOL)enabled    { return FUPrefBool(@"Enabled", YES); }
- (float)threshold { return FUPrefFloat(@"Threshold", 0.5); }
- (NSInteger)method {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Method"), (CFStringRef)kPrefsAppID);
    if (!v) return 0;
    NSInteger m = 0;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        NSString *s = (__bridge NSString *)v;
        if ([s isEqualToString:@"faceprint"]) m = 1;
        else if ([s isEqualToString:@"imageprint"]) m = 2;
    }
    CFRelease(v);
    return m;
}
- (NSUInteger)enrollTarget { return (NSUInteger)MAX(1, FUPrefInt(@"EnrollSamples", 5)); }

#pragma mark - templates
- (void)loadTemplates {
    @synchronized (_templatesLock) {
        [_templates removeAllObjects];
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kTemplateFile];
        NSArray *arr = root[@"templates"];
        if ([arr isKindOfClass:[NSArray class]]) {
            for (NSDictionary *d in arr) {
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                BOOL hasVec  = [d[@"vec"]  isKindOfClass:[NSData class]] && [(NSData *)d[@"vec"] length] > 0;
                BOOL hasArch = [d[@"arch"] isKindOfClass:[NSData class]] && [(NSData *)d[@"arch"] length] > 0;
                if (hasVec || hasArch) [_templates addObject:d];
            }
        }
    }
}

- (void)saveTemplates {
    @try {
        NSArray *snapshot = nil;
        @synchronized (_templatesLock) { snapshot = [_templates copy]; }
        [[NSFileManager defaultManager] createDirectoryAtPath:kTemplateDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL ok = [@{ @"version": @1, @"templates": snapshot } writeToFile:kTemplateFile atomically:YES];
        FU_LOG("saved %lu template(s)%s", (unsigned long)snapshot.count, ok ? "" : " (write failed)");
    } @catch (NSException *e) {
        FU_LOG("saveTemplates failed: %@", e.reason);
    }
}

#pragma mark - scan session lifecycle
// main thread: arm/disarm gates only; the session itself lives on _captureQueue
- (void)startScanning {
    if (_sessionActive) return;
    if (!self.enabled) { FU_LOG("startScanning: disabled by prefs"); return; }
    if (!_passcodeSet) return;   // nothing to unlock without a passcode

    NSUInteger enrolled = 0;
    @synchronized (_templatesLock) { enrolled = _templates.count; }
    BOOL enroll = (enrolled < self.enrollTarget);

    _sessionGen++;
    _sessionActive = YES;
    _analyzing     = YES;
    _enrollRequested = enroll;
    NSUInteger gen = _sessionGen;
    dispatch_async(_captureQueue, ^{
        @autoreleasepool { [self setupAndRunSessionEnroll:enroll gen:gen]; }
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
- (void)setupAndRunSessionEnroll:(BOOL)enroll gen:(NSUInteger)gen {
    @try {
        AVCaptureDeviceDiscoverySession *disc =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                                  mediaType:AVMediaTypeVideo
                                                                   position:AVCaptureDevicePositionFront];
        AVCaptureDevice *cam = disc.devices.firstObject;
        if (!cam) { FU_LOG("startScanning: no front camera found"); [self finishSessionOnQueue]; return; }

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
        if (!input) {
            FU_LOG("startScanning: camera input error: %@", err.localizedDescription ?: @"?");
            [self finishSessionOnQueue];
            return;
        }

        AVCaptureSession *session = [AVCaptureSession new];
        session.sessionPreset = AVCaptureSessionPreset640x480;
        if (![session canAddInput:input]) { FU_LOG("startScanning: cannot add camera input"); [self finishSessionOnQueue]; return; }
        [session addInput:input];

        AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
        out.alwaysDiscardsLateVideoFrames = YES;
        out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
        [out setSampleBufferDelegate:self queue:_captureQueue];
        if (![session canAddOutput:out]) { FU_LOG("startScanning: cannot add video output"); [self finishSessionOnQueue]; return; }
        [session addOutput:out];
        AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
        if (conn.supportsVideoOrientation) conn.videoOrientation = AVCaptureVideoOrientationPortrait;

        NSUInteger enrolled = 0;
        @synchronized (_templatesLock) { enrolled = _templates.count; }

        _consecutive  = 0;
        _sessionBest  = INFINITY;
        _scanDeadline = [NSDate dateWithTimeIntervalSinceNow:enroll ? kEnrollWindow : kScanWindow];
        _runningGen   = gen;
        _session      = session;
        [session startRunning];
        FU_LOG("scanning started (%@ mode, enrolled=%lu target=%lu)", enroll ? @"ENROLL" : @"MATCH",
               (unsigned long)enrolled, (unsigned long)self.enrollTarget);
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
    BOOL hadSession = (_session != nil);
    if (hadSession) {
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
                BOOL wasEnrolling = _enrollRequested;
                [self stopScanning];
                if (wasEnrolling) { _enrollRequested = NO; FU_LOG("enrollment window expired - try again next lock/unlock"); }
                return;
            }

            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pb) return;

            VNDetectFaceRectanglesRequest     *rectReq = [VNDetectFaceRectanglesRequest new];
            VNDetectFaceCaptureQualityRequest *qualReq = [VNDetectFaceCaptureQualityRequest new];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
            NSError *err = nil;
            if (![handler performRequests:@[rectReq, qualReq] error:&err]) {
                [self throttledLog:[NSString stringWithFormat:@"vision detect failed: %@",
                                    err.localizedDescription ?: @"?"]];
                return;
            }
            VNFaceObservation *face = rectReq.results.firstObject;
            if (![face isKindOfClass:[VNFaceObservation class]]) return;
            if (face.faceCaptureQuality && [face.faceCaptureQuality floatValue] < 0.1) return; // dark / blurry

            VNFeaturePrintObservation *print = [self printForFace:face handler:handler pixelBuffer:pb];
            if (!print) return;

            if (_enrollRequested) { [self enrollPrint:print]; return; }

            NSUInteger count = 0;
            NSArray *snapshot = nil;
            @synchronized (_templatesLock) {
                count = _templates.count;
                snapshot = [_templates copy];   // copy under the lock: the array
            }                                    // is mutated on this same queue
            if (count == 0) return;

            float best = INFINITY;
            for (NSDictionary *rec in snapshot) {
                float d = [self distanceRecord:rec toPrint:print];
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

#pragma mark - feature print
// Preferred: private VNGenerateFaceFeaturePrintRequest (real face embedding).
// Fallback: crop the detected face rect, normalize to 256px, public image print.
- (VNFeaturePrintObservation *)printForFace:(VNFaceObservation *)face
                                    handler:(VNImageRequestHandler *)handler
                                pixelBuffer:(CVPixelBufferRef)pb {
    if (self.method != 2) {
        Class cls = NSClassFromString(@"VNGenerateFaceFeaturePrintRequest");
        if (cls) {
            id req = [cls new];
            if ([req respondsToSelector:NSSelectorFromString(@"setInputFaceObservations:")]) {
                @try {
                    [req setValue:@[face] forKey:@"inputFaceObservations"];
                    NSError *e = nil;
                    if ([handler performRequests:@[req] error:&e]) {
                        for (id obs in [req results]) {
                            if ([obs isKindOfClass:[VNFeaturePrintObservation class]]) {
                                static BOOL logged = NO;
                                if (!logged) { logged = YES; FU_LOG("matcher: private face feature print"); }
                                return (VNFeaturePrintObservation *)obs;
                            }
                        }
                    } else {
                        [self throttledLog:[NSString stringWithFormat:@"faceprint request failed: %@",
                                            e.localizedDescription ?: @"?"]];
                    }
                } @catch (NSException *ex) {
                    [self throttledLog:[NSString stringWithFormat:@"faceprint request exception: %@",
                                        ex.reason ?: @"?"]];
                }
            }
        }
    }
    return [self imagePrintForFace:face pixelBuffer:pb];
}

// CoreImage-only on purpose: UIKit drawing is not thread-safe off the main
// thread and is a guaranteed crash source inside a capture delegate queue.
- (VNFeaturePrintObservation *)imagePrintForFace:(VNFaceObservation *)face pixelBuffer:(CVPixelBufferRef)pb {
    static BOOL logged = NO;
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        if (!ci) return nil;
        CGRect ext = ci.extent;
        if (ext.size.width < 1 || ext.size.height < 1) return nil;
        CGRect grow = CGRectInset(face.boundingBox, -0.15, -0.15);   // 15% margin, normalized box
        grow = CGRectIntersection(grow, CGRectMake(0, 0, 1, 1));
        CGRect px = CGRectMake(ext.origin.x + grow.origin.x * ext.size.width,
                               ext.origin.y + grow.origin.y * ext.size.height,
                               grow.size.width  * ext.size.width,
                               grow.size.height * ext.size.height);
        if (px.size.width < 8 || px.size.height < 8) return nil;
        CIImage *cropped = [ci imageByCroppingToRect:px];
        if (!cropped) return nil;

        // normalize to 256x256 in CoreImage space (no UIKit, thread-safe)
        CGFloat sx = kNormalizeSize / px.size.width;
        CGFloat sy = kNormalizeSize / px.size.height;
        CGAffineTransform t = CGAffineTransformMakeScale(sx, sy);
        t = CGAffineTransformTranslate(t, -px.origin.x * sx, -px.origin.y * sy);
        CIImage *norm = [cropped imageByApplyingTransform:t];

        VNGenerateImageFeaturePrintRequest *req = [VNGenerateImageFeaturePrintRequest new];
        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCIImage:norm ?: cropped options:@{}];
        NSError *e = nil;
        if ([h performRequests:@[req] error:&e]) {
            if (!logged) { logged = YES; FU_LOG("matcher: image feature print fallback (256px face crop)"); }
            return req.results.firstObject;
        }
        [self throttledLog:[NSString stringWithFormat:@"imageprint failed: %@", e.localizedDescription ?: @"?"]];
    } @catch (NSException *ex) {
        [self throttledLog:[NSString stringWithFormat:@"imagePrintForFace exception: %@", ex.reason ?: @"?"]];
    }
    return nil;
}

#pragma mark - distance
- (float)distanceRecord:(NSDictionary *)rec toPrint:(VNFeaturePrintObservation *)print {
    NSData *arch = rec[@"arch"];
    if ([arch isKindOfClass:[NSData class]] && arch.length > 0) {
        @try {
            // allow the observation class and its private subclass (faceprints)
            NSMutableSet *classes = [NSMutableSet setWithObject:[VNFeaturePrintObservation class]];
            Class fpObs = NSClassFromString(@"VNFaceFeaturePrintObservation");
            if (fpObs) [classes addObject:fpObs];
            NSError *uerr = nil;
            id tObs = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:arch error:&uerr];
            if ([tObs isKindOfClass:[VNFeaturePrintObservation class]]) {
                float d = 0;
                NSError *e = nil;
                if ([(VNFeaturePrintObservation *)tObs computeDistance:&d
                                            toFeaturePrintObservation:print error:&e]) return d;
            }
        } @catch (NSException *ex) { /* fall through to raw vector */ }
    }
    // raw-vector Euclidean fallback (Apple's computeDistance is a plain Euclidean
    // distance over the print vector; elementType tells us float vs double)
    NSData *a = rec[@"vec"];
    if (![a isKindOfClass:[NSData class]] || !print.data) return INFINITY;
    NSUInteger n = [rec[@"n"] unsignedIntegerValue];
    BOOL isDouble = ([rec[@"t"] integerValue] == VNElementTypeDouble);
    size_t elem = isDouble ? sizeof(double) : sizeof(float);
    if (n == 0 || a.length < n * elem || print.data.length < n * elem) return INFINITY;
    double sum = 0;
    if (isDouble) {
        const double *fa = (const double *)a.bytes, *fb = (const double *)print.data.bytes;
        for (NSUInteger i = 0; i < n; i++) { double d = fa[i] - fb[i]; sum += d * d; }
    } else {
        const float *fa = (const float *)a.bytes, *fb = (const float *)print.data.bytes;
        for (NSUInteger i = 0; i < n; i++) { double d = (double)fa[i] - (double)fb[i]; sum += d * d; }
    }
    return (float)sqrt(sum);
}

#pragma mark - enrollment
- (void)enrollPrint:(VNFeaturePrintObservation *)print {
    // spread samples across the window instead of grabbing 5 identical frames
    if (_lastEnroll && [[NSDate date] timeIntervalSinceDate:_lastEnroll] < kEnrollCooldown) return;
    _lastEnroll = [NSDate date];

    NSData *arch = nil;
    @try {
        arch = [NSKeyedArchiver archivedDataWithRootObject:print requiringSecureCoding:NO error:nil];
    } @catch (NSException *e) { arch = nil; }
    NSData *vec = print.data ?: [NSData data];
    if ((!arch || arch.length == 0) && vec.length == 0) {
        FU_LOG("enroll: faceprint not serializable - skipping sample");
        return;
    }
    // never store NSNull: it is not valid in a property list and would make
    // the whole saveTemplates write throw
    NSDictionary *rec = @{
        @"arch": (arch && arch.length > 0) ? arch : [NSData data],
        @"vec":  vec,
        @"n":    @(print.elementCount),
        @"t":    @(print.elementType),
        @"date": [NSDate date],
    };
    NSUInteger count = 0;
    @synchronized (_templatesLock) {
        [_templates addObject:rec];
        count = _templates.count;
    }
    [self saveTemplates];
    FU_LOG("enrolled faceprint %lu/%lu (elements=%lu type=%ld)",
           (unsigned long)count, (unsigned long)self.enrollTarget,
           (unsigned long)print.elementCount, (long)print.elementType);
    if (count >= self.enrollTarget) {
        _enrollRequested = NO;
        [self stopScanning];
        FU_LOG("enrollment complete - lock the device and look at the camera to test");
    }
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
    if (!self.enabled) return;
    if (!_setUpDone) [self setUp];
    [self startScanning];
}

- (void)noteDeviceLocked {
    self.deviceLocked = YES;
    if (!self.enabled) return;
    if (!_setUpDone) [self setUp];
    [self startScanning];
}

- (void)noteRealUnlock {
    // a real passcode / Touch ID unlock happened: the perfect enrollment moment
    self.deviceLocked = NO;
    [self stopScanning];
    if (!self.enabled) return;
    if (!_setUpDone) [self setUp];
    NSUInteger count = 0;
    @synchronized (_templatesLock) { count = _templates.count; }
    if (count < self.enrollTarget) [self startScanning];   // enroll window
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
                else      [FUMgr() noteRealUnlock];       // real unlock -> enrollment opportunity
            } else {
                [FUMgr() noteDeviceLocked];
            }
        } @catch (NSException *ex) {
            FU_LOG("setAuthenticated hook exception: %@", ex.reason);
        }
    }
}

%end

// Load-time rule: NOTHING SpringBoard-related may run here. Tweaks are injected
// at dyld time, before SpringBoard is initialized — even +sharedInstance on a
// SpringBoard singleton crashes the process (Safe Mode). setUp() is deferred to
// the first lock-screen appearance.
%ctor {
    @autoreleasepool {
        FU_LOG("ctor: injecting into %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
    }
}
