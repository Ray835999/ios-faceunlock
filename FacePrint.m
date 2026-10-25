//
//  FacePrint.m — shared face feature-print pipeline (see FacePrint.h).
//
//  Every Vision class is resolved at runtime (NSClassFromString) so this file
//  is safe to compile into a process where Vision is weak-linked and may fail
//  to load (the SpringBoard tweak). Callers check +visionAvailable first.
//
//  v2.0.1 fixes the "camera runs but never enrolls" bug:
//    1. orientation — a portrait AVCaptureVideoDataOutput buffer is still
//       landscape with the face sideways; the handler was told .up, so no face
//       was ever found. We probe and cache the orientation that works.
//    2. request isolation — the rect and quality requests used to share one
//       performRequests: call whose NO return aborted the whole frame. The rect
//       result is now authoritative and quality is an optional extra.
//    3. crop alignment — the fallback crop now uses the same orientation as the
//       detection, so the feature print is taken from the face, not from a
//       rotated-off-area of the frame.
//

#import "FacePrint.h"
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <math.h>

static NSString *const kTemplateDir  = @"/var/jb/var/mobile/Library/FaceUnlock";
static NSString *const kTemplateFile = @"/var/jb/var/mobile/Library/FaceUnlock/templates.plist";

// Below this face-capture quality a sample is rejected as unusable. Negative
// means "quality unknown" and is never rejected (some devices/setups do not
// populate the property at all).
static const float kMinQuality = 0.05f;

// The orientation the detector last succeeded with (0 = not yet known).
static NSInteger gOrientation = 0;

@interface FacePrint ()
+ (id)handlerForBuffer:(CVPixelBufferRef)pixelBuffer
           orientation:(CGImagePropertyOrientation)orientation;
+ (VNFaceObservation *)detectFaceInBuffer:(CVPixelBufferRef)pixelBuffer
                              orientation:(CGImagePropertyOrientation)orientation
                                  quality:(float *)outQuality;
@end

@implementation FacePrint

#pragma mark - runtime class resolution

+ (Class)handlerClass   { return NSClassFromString(@"VNImageRequestHandler"); }
+ (Class)faceRectClass  { return NSClassFromString(@"VNDetectFaceRectanglesRequest"); }
+ (Class)faceQualClass  { return NSClassFromString(@"VNDetectFaceCaptureQualityRequest"); }
+ (Class)faceObsClass   { return NSClassFromString(@"VNFaceObservation"); }
+ (Class)imgPrintClass  { return NSClassFromString(@"VNGenerateImageFeaturePrintRequest"); }
+ (Class)printObsClass  { return NSClassFromString(@"VNFeaturePrintObservation"); }
+ (Class)facePrintClass { return NSClassFromString(@"VNGenerateFaceFeaturePrintRequest"); }

+ (BOOL)visionAvailable {
    return (self.handlerClass != nil
         && self.faceRectClass != nil
         && self.faceObsClass != nil
         && self.imgPrintClass != nil
         && self.printObsClass != nil);
}

#pragma mark - orientation

+ (NSInteger)workingOrientation {
    @synchronized (self) { return gOrientation; }
}

+ (NSString *)orientationName:(NSInteger)o {
    switch ((CGImagePropertyOrientation)o) {
        case kCGImagePropertyOrientationUp:            return @"up";
        case kCGImagePropertyOrientationDown:          return @"down";
        case kCGImagePropertyOrientationLeft:          return @"left";
        case kCGImagePropertyOrientationRight:         return @"right";
        case kCGImagePropertyOrientationUpMirrored:    return @"upMirrored";
        case kCGImagePropertyOrientationDownMirrored:  return @"downMirrored";
        case kCGImagePropertyOrientationLeftMirrored:  return @"leftMirrored";
        case kCGImagePropertyOrientationRightMirrored: return @"rightMirrored";
        default:                                       return @"unknown";
    }
}

+ (id)handlerForBuffer:(CVPixelBufferRef)pixelBuffer
           orientation:(CGImagePropertyOrientation)orientation {
    Class cls = self.handlerClass;
    if (!cls) return nil;
    // the orientation-aware initialiser is the whole point of this fix; fall
    // back only if the runtime somehow lacks it
    if ([cls instancesRespondToSelector:@selector(initWithCVPixelBuffer:orientation:options:)]) {
        @try {
            return [[cls alloc] initWithCVPixelBuffer:pixelBuffer
                                          orientation:orientation
                                              options:@{}];
        } @catch (NSException *ex) {
            // fall through to the legacy initialiser
        }
    }
    @try {
        return [[cls alloc] initWithCVPixelBuffer:pixelBuffer options:@{}];
    } @catch (NSException *ex) {
        return nil;
    }
}

#pragma mark - detection

+ (VNFaceObservation *)detectFaceInBuffer:(CVPixelBufferRef)pixelBuffer
                              orientation:(CGImagePropertyOrientation)orientation
                                  quality:(float *)outQuality {
    if (outQuality) *outQuality = -1.0f;
    if (!pixelBuffer || ![self visionAvailable]) return nil;

    VNFaceObservation *face = nil;
    @try {
        id rectReq = [self.faceRectClass new];
        if (!rectReq) return nil;
        id<FUVNRequestHandler> handler = [self handlerForBuffer:pixelBuffer
                                                    orientation:orientation];
        if (!handler) return nil;

        // The face-rect request alone decides whether there is a face. Its
        // result is read even when performRequests: reports a failure, because
        // one bad sibling request must not throw the whole frame away.
        NSError *err = nil;
        @try { [handler performRequests:@[rectReq] error:&err]; } @catch (NSException *ex) {}
        id results = [rectReq valueForKey:@"results"];
        if (![results isKindOfClass:[NSArray class]] || [results count] == 0) return nil;
        id first = [results firstObject];
        if (![first isKindOfClass:self.faceObsClass]) return nil;
        face = (VNFaceObservation *)first;

        // Quality is a best-effort annotation, never a gate on detection.
        Class qualCls = self.faceQualClass;
        if (qualCls) {
            @try {
                id qualReq = [qualCls new];
                if (qualReq) {
                    NSError *qe = nil;
                    @try { [handler performRequests:@[qualReq] error:&qe]; } @catch (NSException *ex) {}
                    id qr = [qualReq valueForKey:@"results"];
                    if ([qr isKindOfClass:[NSArray class]] && [qr count] == [results count]) {
                        id q0 = [qr firstObject];
                        id v = [q0 valueForKey:@"faceCaptureQuality"];
                        if ([v isKindOfClass:[NSNumber class]] && outQuality) {
                            *outQuality = [v floatValue];
                        }
                    }
                }
            } @catch (NSException *ex) {
                // quality unknown — leave -1
            }
        }
        return face;
    } @catch (NSException *ex) {
        return nil;
    }
}

+ (VNFaceObservation *)detectFaceInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   qualityGate:(BOOL)qualityGate {
    return [self detectFaceInPixelBuffer:pixelBuffer qualityGate:qualityGate quality:NULL];
}

+ (VNFaceObservation *)detectFaceInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   qualityGate:(BOOL)qualityGate
                                       quality:(float *)outQuality {
    if (outQuality) *outQuality = -1.0f;
    if (!pixelBuffer || ![self visionAvailable]) return nil;

    NSInteger cached;
    @synchronized (self) { cached = gOrientation; }
    if (cached > 0) {
        float q = -1;
        VNFaceObservation *f = [self detectFaceInBuffer:pixelBuffer
                                            orientation:(CGImagePropertyOrientation)cached
                                                quality:&q];
        if (f) {
            if (qualityGate && q >= 0 && q < kMinQuality) {
                if (outQuality) *outQuality = q;   // caller can say "too dark"
                return nil;
            }
            if (outQuality) *outQuality = q;
            return f;
        }
        // No face with the remembered orientation — the device may have been
        // rotated. Fall through and probe again rather than staying blind.
    }

    // Fixed probe order. "right" is what a portrait front camera needs on
    // every iPhone this project targets, so it is tried first; the rest are
    // fallbacks for landscape holds and mirrored buffer setups. App and tweak
    // use the same device/preset/format, so they settle on the same value and
    // their feature prints stay comparable.
    static const CGImagePropertyOrientation kOrder[] = {
        kCGImagePropertyOrientationRight,
        kCGImagePropertyOrientationLeft,
        kCGImagePropertyOrientationUp,
        kCGImagePropertyOrientationDown,
        kCGImagePropertyOrientationRightMirrored,
        kCGImagePropertyOrientationLeftMirrored,
        kCGImagePropertyOrientationUpMirrored,
        kCGImagePropertyOrientationDownMirrored,
    };
    for (size_t i = 0; i < sizeof(kOrder) / sizeof(kOrder[0]); i++) {
        float q = -1;
        VNFaceObservation *f = [self detectFaceInBuffer:pixelBuffer
                                            orientation:kOrder[i]
                                                quality:&q];
        if (!f) continue;
        @synchronized (self) { gOrientation = (NSInteger)kOrder[i]; }
        NSLog(@"[FaceUnlock] orientation locked to %@ (probe #%zu)",
              [self orientationName:(NSInteger)kOrder[i]], i + 1);
        if (qualityGate && q >= 0 && q < kMinQuality) {
            // face found but unusable: still report it so the UI can say
            // "too dark" instead of "no face"
            if (outQuality) *outQuality = q;
            return nil;
        }
        if (outQuality) *outQuality = q;
        return f;
    }
    return nil;
}

#pragma mark - feature print

+ (VNFeaturePrintObservation *)observationForFace:(VNFaceObservation *)face
                                      pixelBuffer:(CVPixelBufferRef)pixelBuffer
                                       logPrefix:(NSString *)logPrefix {
    if (!face || ![self visionAvailable]) return nil;

    NSInteger o;
    @synchronized (self) { o = gOrientation; }
    if (o <= 0) o = (NSInteger)kCGImagePropertyOrientationRight;

    @try {
        id<FUVNRequestHandler> handler = [self handlerForBuffer:pixelBuffer
                                                    orientation:(CGImagePropertyOrientation)o];
        if (!handler) return nil;

        // preferred: private VNGenerateFaceFeaturePrintRequest (Photos-grade embedding)
        Class fpCls = self.facePrintClass;
        if (fpCls) {
            id req = [fpCls new];
            if (req && [req respondsToSelector:NSSelectorFromString(@"setInputFaceObservations:")]) {
                @try {
                    [req setValue:@[face] forKey:@"inputFaceObservations"];
                    NSError *e = nil;
                    if ([handler performRequests:@[req] error:&e]) {
                        id results = [req valueForKey:@"results"];
                        for (id obs in results) {
                            if ([obs isKindOfClass:self.printObsClass]) {
                                static BOOL logged = NO;
                                if (!logged) {
                                    logged = YES;
                                    NSLog(@"[FaceUnlock] %@ matcher: private face feature print",
                                          logPrefix);
                                }
                                return (VNFeaturePrintObservation *)obs;
                            }
                        }
                    }
                } @catch (NSException *ex) {
                    // fall through to the public image-print path
                }
            }
        }

        // fallback: crop the face rect and normalise to 256px.
        // The image is first oriented exactly like the detection was, so the
        // Vision bounding box (bottom-left origin, oriented space) maps
        // straight onto the CIImage extent.
        @try {
            CIImage *base = [CIImage imageWithCVPixelBuffer:pixelBuffer];
            if (!base) return nil;
            CIImage *oriented = nil;
            @try {
                oriented = [base imageByApplyingOrientation:(CGImagePropertyOrientation)o];
            } @catch (NSException *ex) {
                oriented = nil;
            }
            CIImage *src = oriented.extent.size.width > 0 ? oriented : base;
            CGRect ext = src.extent;
            if (ext.size.width < 1 || ext.size.height < 1) return nil;

            CGRect grow = CGRectInset(face.boundingBox, -0.15, -0.15);   // 15% margin
            grow = CGRectIntersection(grow, CGRectMake(0, 0, 1, 1));
            if (CGRectIsNull(grow) || CGRectIsEmpty(grow)) return nil;

            CGRect px = CGRectMake(ext.origin.x + grow.origin.x * ext.size.width,
                                   ext.origin.y + grow.origin.y * ext.size.height,
                                   grow.size.width  * ext.size.width,
                                   grow.size.height * ext.size.height);
            if (px.size.width < 8 || px.size.height < 8) return nil;
            CIImage *cropped = [src imageByCroppingToRect:px];
            if (!cropped) return nil;

            // scale so the short side reaches 256, then centre-crop to 256x256
            CGFloat scale = 256.0 / MAX(1.0, MIN(px.size.width, px.size.height));
            CIImage *scaled = [cropped imageByApplyingTransform:
                                  CGAffineTransformMakeScale(scale, scale)];
            scaled = [scaled imageByApplyingTransform:
                         CGAffineTransformMakeTranslation(-scaled.extent.origin.x,
                                                          -scaled.extent.origin.y)];
            CGRect se = scaled.extent;
            CGRect normRect = CGRectMake(MAX(0.0, (se.size.width  - 256.0) / 2.0),
                                         MAX(0.0, (se.size.height - 256.0) / 2.0),
                                         256.0, 256.0);
            CIImage *norm = [scaled imageByCroppingToRect:normRect];

            id req = [self.imgPrintClass new];
            if (!req) return nil;
            id<FUVNRequestHandler> h =
                [[self.handlerClass alloc] initWithCIImage:norm ?: cropped options:@{}];
            NSError *e = nil;
            if (h && [h performRequests:@[req] error:&e]) {
                static BOOL logged = NO;
                if (!logged) {
                    logged = YES;
                    NSLog(@"[FaceUnlock] %@ matcher: image feature print fallback (256px crop)",
                          logPrefix);
                }
                id results = [req valueForKey:@"results"];
                if ([results isKindOfClass:[NSArray class]]) {
                    for (id obs in results) {
                        if ([obs isKindOfClass:self.printObsClass]) {
                            return (VNFeaturePrintObservation *)obs;
                        }
                    }
                }
            }
        } @catch (NSException *ex) {
            // give up on this frame
        }
    } @catch (NSException *ex) {
        // give up on this frame
    }
    return nil;
}

#pragma mark - template persistence
+ (NSDictionary *)templateForPrint:(VNFeaturePrintObservation *)print {
    NSData *arch = nil;
    @try {
        arch = [NSKeyedArchiver archivedDataWithRootObject:print requiringSecureCoding:NO error:nil];
    } @catch (NSException *e) {
        arch = nil;
    }
    NSData *vec = print.data ?: [NSData data];
    // never NSNull: it is invalid in a property list and would make the whole
    // write throw
    return @{
        @"arch": (arch && arch.length > 0) ? arch : [NSData data],
        @"vec":  vec,
        @"n":    @(print.elementCount),
        @"t":    @(print.elementType),
        @"date": [NSDate date],
    };
}

+ (BOOL)saveTemplates:(NSArray *)templates {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:kTemplateDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        return [@{ @"version": @1, @"templates": templates }
                writeToFile:kTemplateFile atomically:YES];
    } @catch (NSException *e) {
        return NO;
    }
}

+ (NSArray *)loadTemplates {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kTemplateFile];
        NSArray *arr = root[@"templates"];
        if ([arr isKindOfClass:[NSArray class]]) {
            for (NSDictionary *d in arr) {
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                BOOL hasVec  = [d[@"vec"]  isKindOfClass:[NSData class]] && [(NSData *)d[@"vec"] length]  > 0;
                BOOL hasArch = [d[@"arch"] isKindOfClass:[NSData class]] && [(NSData *)d[@"arch"] length] > 0;
                if (hasVec || hasArch) [out addObject:d];
            }
        }
    } @catch (NSException *e) {
        // treat as "no templates"
    }
    return out;
}

+ (BOOL)deleteTemplates {
    @try {
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:kTemplateFile error:&err];
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - distance
+ (float)distanceFromTemplate:(NSDictionary *)tmpl
                      toPrint:(VNFeaturePrintObservation *)print {
    NSData *arch = tmpl[@"arch"];
    if ([arch isKindOfClass:[NSData class]] && arch.length > 0) {
        @try {
            // allow the observation class and its private subclass (faceprints)
            NSMutableSet *classes = [NSMutableSet setWithObject:self.printObsClass];
            Class fpObs = NSClassFromString(@"VNFaceFeaturePrintObservation");
            if (fpObs) [classes addObject:fpObs];
            NSError *uerr = nil;
            id tObs = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:arch error:&uerr];
            if ([tObs conformsToProtocol:@protocol(FUVNFeaturePrintObservation)]) {
                float d = 0;
                NSError *e = nil;
                if ([(id<FUVNFeaturePrintObservation>)tObs computeDistance:&d
                                            toFeaturePrintObservation:print error:&e]) return d;
            }
        } @catch (NSException *ex) {
            // fall through to the raw-vector path
        }
    }
    // raw-vector Euclidean fallback (Apple's computeDistance is a plain
    // Euclidean distance over the print vector; elementType gives float/double)
    NSData *a = tmpl[@"vec"];
    if (![a isKindOfClass:[NSData class]] || !print.data) return INFINITY;
    NSUInteger n = [tmpl[@"n"] unsignedIntegerValue];
    BOOL isDouble = ([tmpl[@"t"] integerValue] == VNElementTypeDouble);
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

@end
