//
//  FacePrint.h — shared face feature-print pipeline.
//
//  Compiled into BOTH the SpringBoard tweak and the FaceUnlockSettings app so
//  enrollment (app) and matching (tweak) use byte-identical logic and produce
//  mutually comparable prints.
//
//  SAFETY (Safe Mode post-mortem v1.2.0): the tweak weak-links Vision and
//  AVFoundation. Every Vision class is therefore looked up at runtime via
//  NSClassFromString and every entry point bails out gracefully when the
//  framework is unavailable — a missing framework must disable the feature,
//  never crash the host process.
//
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

// Minimal protocols used to message runtime-resolved Vision objects without
// referencing the classes directly (safe under -weak_framework Vision).
@protocol FUVNRequestHandler <NSObject>
- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer options:(NSDictionary *)options;
- (instancetype)initWithCIImage:(CIImage *)image options:(NSDictionary *)options;
- (BOOL)performRequests:(NSArray *)requests error:(NSError **)error;
@end

@protocol FUVNFeaturePrintObservation <NSObject>
- (BOOL)computeDistance:(float *)distance toFeaturePrintObservation:(id)print error:(NSError **)error;
@end

@interface FacePrint : NSObject

// YES when the Vision classes this pipeline needs are present in the process.
+ (BOOL)visionAvailable;

// Full pipeline for one pixel buffer: caller has already located the face.
// Private VNGenerateFaceFeaturePrintRequest first (real face embedding),
// public crop + VNGenerateImageFeaturePrintRequest as fallback.
+ (VNFeaturePrintObservation *)observationForFace:(VNFaceObservation *)face
                                      pixelBuffer:(CVPixelBufferRef)pixelBuffer
                                       logPrefix:(NSString *)logPrefix;

// Detect the first usable face in a pixel buffer (quality >= 0.1 when gated).
+ (VNFaceObservation *)detectFaceInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   qualityGate:(BOOL)qualityGate;

// Template record for persistence (never contains NSNull — plist-safe).
+ (NSDictionary *)templateForPrint:(VNFeaturePrintObservation *)print;

+ (BOOL)saveTemplates:(NSArray *)templates;
+ (NSArray *)loadTemplates;
+ (BOOL)deleteTemplates;

// Distance between a stored template and a live print.
// VNFeaturePrintObservation computeDistance: first, raw-vector Euclidean fallback.
+ (float)distanceFromTemplate:(NSDictionary *)tmpl
                      toPrint:(VNFeaturePrintObservation *)print;

@end
