//
//  FaceUnlockSettings.h — companion app: enroll / manage faceprints.
//

#import <UIKit/UIKit.h>

@interface FUSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface FUSMainViewController : UITableViewController
@end

@interface FUSEnrollViewController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate>
@end
