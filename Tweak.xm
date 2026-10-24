//
//  FaceUnlock — camera-based face unlock for Touch ID devices
//  Target: iPhone 6s / iOS 15.8.x / rootless palera1n (Dopamine)
//
//  Design (all private API access is runtime-guarded):
//   1. On lock screen (SBDashBoardViewController viewDidAppear) start the front
//      camera and run Vision face detection + feature print per frame (~3 fps).
//   2. Enrollment: the first N real unlocks (passcode / Touch ID) capture your
//      faceprints. No companion app needed.
//   3. Match: min distance vs stored prints < threshold for 2 consecutive
//      frames -> setAuthenticated:YES then
//      SBLockScreenManager lockScreenViewControllerRequestsUnlock
//      (the same unlock-completion call FastUnlockX uses).
//
//  Verified against iPhoneOS15.6.sdk headers:
//   - VNFeaturePrintObservation computeDistance:toFeaturePrintObservation:error:
//   - VNObservation : NSSecureCoding  (prints are archivable)
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

#define FU_LOG(fmt, ...) NSLog(@"[FaceUnlock] " fmt, ##__VA_ARGS__)

static NSString *const kPrefsAppID   = @"com.ray835999.faceunlock";
static NSString *const kTemplateDir  = @"/var/jb/var/mobile/Library/FaceUnlock";
static NSString *const kTemplateFile = @"/var/jb/var/mobile/Library/FaceUnlock/templates.plist";

static const NSTimeInterval kScanWindow        = 12.0;  // auto-stop without a match
static const NSTimeInterval kEnrollWindow      = 6.0;   // enrollment capture window
static const NSTimeInterval kAnalysisInterval  = 0.35;  // ~3 fps
static const NSTimeInterval kLogInterval       = 2.0;
static const NSUInteger    kRequiredConsecutive = 2;

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
    AVCaptureSession  *_session;
    NSMutableArray    *_templates;   // @{ @"arch":NSData, @"vec":NSData, @"n":uint, @"t":uint }
    NSDate            *_lastAnalysis;
    NSDate            *_scanDeadline;
    NSTimeInterval     _lastLog;
    NSUInteger         _consecutive;
    BOOL               _enrollRequested;
    BOOL               _analyzing;
    BOOL               _setUpDone;
    float              _sessionBest;
}

+ (instancetype)sharedManager {
    static FaceUnlockManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [FaceUnlockManager new]; });
    return m;
}

- (void)setUp {
    if (_setUpDone) return;
    _setUpDone = YES;
    _templates = [NSMutableArray array];
    [self loadTemplates];
    Class fp = NSClassFromString(@"VNGenerateFaceFeaturePrintRequest");
    BOOL passcode = YES;
    id lockMgr = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (lockMgr && [lockMgr respondsToSelector:@selector(isPasscodeSet)]) {
        passcode = ((BOOL (*)(id, SEL))objc_msgSend)(lockMgr, @selector(isPasscodeSet));
    }
    FU_LOG("loaded: enabled=%d threshold=%.3f method=%ld enrolled=%lu passcodeSet=%d faceprintClass=%s",
           FUPrefBool(@"Enabled", YES), FUPrefFloat(@"Threshold", 0.5), (long)[self method],
           (unsigned long)_templates.count, passcode, fp ? "yes" : "no->image-print fallback");
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
    [_templates removeAllObjects];
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kTemplateFile];
    NSArray *arr = root[@"templates"];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in arr) {
            if ([d isKindOfClass:[NSDictionary class]] && [d[@"vec"] isKindOfClass:[NSData class]]) {
                [_templates addObject:d];
            }
        }
    }
}

- (void)saveTemplates {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:kTemplateDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [@{ @"version": @1, @"templates": _templates } writeToFile:kTemplateFile atomically:YES];
        FU_LOG("saved %lu template(s) -> %@", (unsigned long)_templates.count, kTemplateFile);
    } @catch (NSException *e) {
        FU_LOG("saveTemplates failed: %@", e.reason);
    }
}

#pragma mark - capture
- (void)startScanning {
    if (_session) return;
    if (!self.enabled) { FU_LOG("startScanning: disabled by prefs"); return; }
    if (_templates.count == 0 && !_enrollRequested) {
        FU_LOG("startScanning: no faceprints yet (unlock once with your passcode to enroll)");
        return;
    }

    AVCaptureDevice *cam = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                             mediaType:AVMediaTypeVideo
                                                              position:AVCaptureDevicePositionFront];
    if (!cam) {
        for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
            if (d.position == AVCaptureDevicePositionFront) { cam = d; break; }
        }
    }
    if (!cam) { FU_LOG("startScanning: no front camera found"); return; }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
    if (!input) { FU_LOG("startScanning: camera input error: %@", err.localizedDescription ?: @"?"); return; }

    AVCaptureSession *session = [AVCaptureSession new];
    session.sessionPreset = AVCaptureSessionPreset640x480;
    if (![session canAddInput:input]) { FU_LOG("startScanning: cannot add camera input"); return; }
    [session addInput:input];

    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.alwaysDiscardsLateVideoFrames = YES;
    out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    dispatch_queue_t q = dispatch_queue_create("com.ray835999.faceunlock.capture", DISPATCH_QUEUE_SERIAL);
    [out setSampleBufferDelegate:self queue:q];
    if (![session canAddOutput:out]) { FU_LOG("startScanning: cannot add video output"); return; }
    [session addOutput:out];
    AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
    if (conn.isCameraIntrinsicMatrixDeliverySupported) conn.cameraIntrinsicMatrixDelivery = YES;
    if (conn.supportsVideoOrientation) conn.videoOrientation = AVCaptureVideoOrientationPortrait;

    _consecutive   = 0;
    _sessionBest   = INFINITY;
    _scanDeadline  = [NSDate dateWithTimeIntervalSinceNow:_enrollRequested ? kEnrollWindow : kScanWindow];
    _analyzing     = YES;
    _session       = session;
    [session startRunning];
    FU_LOG("scanning started (%@ mode, enroll target=%lu)", _enrollRequested ? @"ENROLL" : @"MATCH",
           (unsigned long)self.enrollTarget);
}

- (void)stopScanning {
    _analyzing = NO;
    if (_sessionBest != INFINITY) {
        [self throttledLog:[NSString stringWithFormat:@"scan session best distance=%.3f (threshold=%.3f)",
                            _sessionBest, self.threshold]];
        _sessionBest = INFINITY;
    }
    if (!_session) return;
    [_session stopRunning];
    _session = nil;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
      fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if (!_analyzing || !_session) return;
        NSDate *now = [NSDate date];
        if (_lastAnalysis && [now timeIntervalSinceDate:_lastAnalysis] < kAnalysisInterval) return;
        _lastAnalysis = now;
        if ([now timeIntervalSinceDate:_scanDeadline] > 0) {
            BOOL wasEnrolling = _enrollRequested;
            [self stopScanning];
            if (wasEnrolling) { _enrollRequested = NO; FU_LOG("enrollment window expired - try again next unlock"); }
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
        if (_templates.count == 0) return;

        float best = INFINITY;
        for (NSDictionary *rec in _templates) {
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

- (VNFeaturePrintObservation *)imagePrintForFace:(VNFaceObservation *)face pixelBuffer:(CVPixelBufferRef)pb {
    static BOOL logged = NO;
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        if (!ci) return nil;
        CGSize sz = ci.extent.size;
        if (sz.width < 1 || sz.height < 1) return nil;
        CGRect grow = CGRectInset(face.boundingBox, -0.15, -0.15);   // 15% margin, normalized box
        grow = CGRectIntersection(grow, CGRectMake(0, 0, 1, 1));
        CGRect px = CGRectMake(grow.origin.x * sz.width, grow.origin.y * sz.height,
                               grow.size.width * sz.width, grow.size.height * sz.height);
        CIImage *cropped = [ci imageByCroppingToRect:px];
        UIImage *ui = [UIImage imageWithCIImage:cropped];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(256, 256), NO, 1.0);
        [ui drawInRect:CGRectMake(0, 0, 256, 256)];
        UIImage *norm = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!norm || !norm.CGImage) return nil;

        VNGenerateImageFeaturePrintRequest *req = [VNGenerateImageFeaturePrintRequest new];
        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:norm.CGImage options:@{}];
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
    if ([arch isKindOfClass:[NSData class]]) {
        @try {
            id tObs = [NSKeyedUnarchiver unarchiveObjectWithData:arch];
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
    NSData *arch = nil;
    @try {
        arch = [NSKeyedArchiver archivedDataWithRootObject:print requiringSecureCoding:NO error:nil];
    } @catch (NSException *e) { arch = nil; }
    [_templates addObject:@{
        @"arch": arch ?: [NSNull null],
        @"vec":  print.data ?: [NSNull null],
        @"n":    @(print.elementCount),
        @"t":    @(print.elementType),
        @"date": [NSDate date],
    }];
    [self saveTemplates];
    FU_LOG("enrolled faceprint %lu/%lu (elements=%lu type=%ld)",
           (unsigned long)_templates.count, (unsigned long)self.enrollTarget,
           (unsigned long)print.elementCount, (long)print.elementType);
    if (_templates.count >= self.enrollTarget) {
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
        id vc = self.dashBoardVC;
        BOOL called = NO;
        if (vc && [vc respondsToSelector:@selector(setAuthenticated:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, @selector(setAuthenticated:), YES);
            called = YES;
        }
        if (!called) FU_LOG("setAuthenticated: unavailable - using unlock-request fallback");
        // safety net: if the hook never completes the unlock, force it shortly after
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.faceUnlockInProgress) {
                FU_LOG("safety net: forcing unlock request");
                [self completeFaceUnlock];
            }
        });
    });
}

// Mirrors FastUnlockX (CP Digital Darkroom, MIT): after authentication the lock
// screen asks SBLockScreenManager to complete the unlock.
- (void)completeFaceUnlock {
    id lockMgr = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    SEL sel = @selector(lockScreenViewControllerRequestsUnlock);
    if (lockMgr && [lockMgr respondsToSelector:sel]) {
        [lockMgr performSelector:sel];
        FU_LOG("lockScreenViewControllerRequestsUnlock sent");
    } else {
        FU_LOG("SBLockScreenManager / lockScreenViewControllerRequestsUnlock unavailable");
    }
    self.faceUnlockInProgress = NO;
}

#pragma mark - state transitions
- (void)lockScreenDidAppear {
    self.deviceLocked = YES;
    if (self.enabled && _templates.count > 0) [self startScanning];
}

- (void)noteDeviceLocked {
    self.deviceLocked = YES;
    if (self.enabled && _templates.count > 0) [self startScanning];
}

- (void)noteRealUnlock {
    // a real passcode / Touch ID unlock happened: the perfect enrollment moment
    self.deviceLocked = NO;
    [self stopScanning];
    if (self.enabled && _templates.count < self.enrollTarget) {
        _enrollRequested = YES;
        FU_LOG("enrollment: real unlock #%lu - capturing your faceprint",
               (unsigned long)_templates.count + 1);
        [self startScanning];
    }
}

@end

// ---------------------------------------------------------------------------
// hooks
// ---------------------------------------------------------------------------
static inline FaceUnlockManager *FUMgr(void) { return [FaceUnlockManager sharedManager]; }

%hook SBDashBoardViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    FUMgr().dashBoardVC = self;
    [FUMgr() lockScreenDidAppear];
}

- (void)setAuthenticated:(BOOL)authenticated {
    BOOL ours = FUMgr().faceUnlockInProgress;
    %orig;
    if (authenticated) {
        if (ours) [FUMgr() completeFaceUnlock];   // finish the unlock we requested
        else      [FUMgr() noteRealUnlock];       // real unlock -> enrollment opportunity
    } else {
        [FUMgr() noteDeviceLocked];
    }
}

%end

%ctor {
    @autoreleasepool {
        FU_LOG("ctor: injecting into %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
        [FUMgr() setUp];
    }
}
