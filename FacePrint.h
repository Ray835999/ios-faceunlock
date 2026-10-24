//
//  FacePrint.h — shared face feature-print pipeline.
//
//  Compiled into BOTH the SpringBoard tweak and the FaceUnlockSettings app so
//  enrollment (app) and matching (tweak) use byte-identical logic and produce
//  mutually comparable prints.
//
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

@interface FacePrint : NSObject

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
