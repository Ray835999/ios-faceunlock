//
//  FacePrint.m — shared face feature-print pipeline (see FacePrint.h).
//
//  Every Vision class is resolved at runtime (NSClassFromString) so this file
//  is safe to compile into a process where Vision is weak-linked and may fail
//  to load (the SpringBoard tweak). Callers check +visionAvailable first.
//

#import "FacePrint.h"
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <math.h>

static NSString *const kTemplateDir  = @"/var/jb/var/mobile/Library/FaceUnlock";
static NSString *const kTemplateFile = @"/var/jb/var/mobile/Library/FaceUnlock/templates.plist";

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
         && self.faceQualClass != nil
         && self.faceObsClass != nil
         && self.imgPrintClass != nil
         && self.printObsClass != nil);
}

#pragma mark - detection
+ (VNFaceObservation *)detectFaceInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   qualityGate:(BOOL)qualityGate {
    if (![self visionAvailable]) return nil;
    @try {
        id rectReq = [self.faceRectClass new];
        id qualReq = [self.faceQualClass new];
        if (!rectReq || !qualReq) return nil;
        id<FUVNRequestHandler> handler =
            [[self.handlerClass alloc] initWithCVPixelBuffer:pixelBuffer options:@{}];
        if (!handler) return nil;
        NSError *err = nil;
        if (![handler performRequests:@[rectReq, qualReq] error:&err]) return nil;
        id results = [rectReq valueForKey:@"results"];
        id face = [results isKindOfClass:[NSArray class]] ? [results firstObject] : nil;
        if (![face isKindOfClass:self.faceObsClass]) return nil;
        if (qualityGate) {
            NSNumber *q = [face valueForKey:@"faceCaptureQuality"];
            if (q && [q isKindOfClass:[NSNumber class]] && q.floatValue < 0.1) {
                return nil; // dark / blurry
            }
        }
        return (VNFaceObservation *)face;
    } @catch (NSException *ex) {
        return nil;
    }
}

#pragma mark - feature print
+ (VNFeaturePrintObservation *)observationForFace:(VNFaceObservation *)face
                                      pixelBuffer:(CVPixelBufferRef)pixelBuffer
                                       logPrefix:(NSString *)logPrefix {
    if (![self visionAvailable]) return nil;
    @try {
        id<FUVNRequestHandler> handler =
            [[self.handlerClass alloc] initWithCVPixelBuffer:pixelBuffer options:@{}];
        if (!handler) return nil;

        // preferred: private VNGenerateFaceFeaturePrintRequest (Photos-grade embedding)
        Class fpCls = self.facePrintClass;
        if (fpCls) {
            id req = [fpCls new];
            if ([req respondsToSelector:NSSelectorFromString(@"setInputFaceObservations:")]) {
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
                                    NSLog(@"[FaceUnlock] %@ matcher: private face feature print", logPrefix);
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

        // fallback: crop the face rect, normalize to 256px, public image print.
        // CoreImage only — UIKit drawing is not thread-safe off the main thread.
        @try {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
            if (!ci) return nil;
            CGRect ext = ci.extent;
            if (ext.size.width < 1 || ext.size.height < 1) return nil;
            CGRect grow = CGRectInset(face.boundingBox, -0.15, -0.15);   // 15% margin
            grow = CGRectIntersection(grow, CGRectMake(0, 0, 1, 1));
            CGRect px = CGRectMake(ext.origin.x + grow.origin.x * ext.size.width,
                                   ext.origin.y + grow.origin.y * ext.size.height,
                                   grow.size.width  * ext.size.width,
                                   grow.size.height * ext.size.height);
            if (px.size.width < 8 || px.size.height < 8) return nil;
            CIImage *cropped = [ci imageByCroppingToRect:px];
            if (!cropped) return nil;

            CGFloat sx = 256.0 / px.size.width;
            CGFloat sy = 256.0 / px.size.height;
            CGAffineTransform t = CGAffineTransformMakeScale(sx, sy);
            t = CGAffineTransformTranslate(t, -px.origin.x * sx, -px.origin.y * sy);
            CIImage *norm = [cropped imageByApplyingTransform:t];

            id req = [self.imgPrintClass new];
            id<FUVNRequestHandler> h =
                [[self.handlerClass alloc] initWithCIImage:norm ?: cropped options:@{}];
            NSError *e = nil;
            if (h && [h performRequests:@[req] error:&e]) {
                static BOOL logged = NO;
                if (!logged) {
                    logged = YES;
                    NSLog(@"[FaceUnlock] %@ matcher: image feature print fallback (256px crop)", logPrefix);
                }
                id results = [req valueForKey:@"results"];
                return (VNFeaturePrintObservation *)[results firstObject];
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
