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
//  ORIENTATION (v2.0.1 post-mortem "camera runs but never enrolls"):
//  AVCaptureVideoDataOutput does NOT rotate its buffers to match
//  connection.videoOrientation — portrait capture still arrives as a landscape
//  640x480 frame with the face lying on its side. Vision was being fed that
//  frame with the default .up orientation, so the face detector found nothing.
//  Both processes now probe orientations in a fixed order and cache the first
//  one that actually yields a face. Because app and tweak use the same device,
//  preset and format, they converge on the same value and stay comparable.
//
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

// Minimal protocols used to message runtime-resolved Vision objects without
// referencing the classes directly (safe under -weak_framework Vision).
@protocol FUVNRequestHandler <NSObject>
- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer options:(NSDictionary *)options;
- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          orientation:(CGImagePropertyOrientation)orientation
                              options:(NSDictionary *)options;
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

// Detect the first usable face in a pixel buffer.
// Probes CGImagePropertyOrientation values in a fixed order and caches the one
// that works, so a sideways buffer is handled automatically.
+ (VNFaceObservation *)detectFaceInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   qualityGate:(BOOL)qualityGate;

// Same, but reports the face-capture quality (0..1, negative when unknown) so
// the enrollment UI can say "too dark" instead of "no face".
+ (VNFaceObservation *)detectFaceInPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   qualityGate:(BOOL)qualityGate
                                       quality:(float *)outQuality;

// Diagnostics: the orientation the detector settled on (0 = still unknown).
+ (NSInteger)workingOrientation;
+ (NSString *)orientationName:(NSInteger)orientation;

// Diagnostics: where the last detection stopped, e.g.
//   "rect: 0 faces (right)"  -> the request ran but found nothing
//   "no handler"             -> Vision could not even be messaged
//   "exception: ..."         -> Vision threw
// The enrollment UI shows this verbatim so a screenshot is enough to diagnose.
+ (NSString *)lastDetectNote;

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
