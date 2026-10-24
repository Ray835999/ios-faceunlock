//
//  FaceUnlockSettings.h — companion app: enroll / manage faceprints.
//

#import <UIKit/UIKit.h>

// AVFoundation protocol, forward-declared to keep this header light.
@protocol AVCaptureVideoDataOutputSampleBufferDelegate;

@interface FUSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface FUSMainViewController : UITableViewController
@end

@interface FUSEnrollViewController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate>
@end
