//
//  FaceUnlockSettings.h — companion app for the FaceUnlock tweak (v2.0.0).
//
//  Deliberately minimal: a plain UIViewController with hand-placed UIButtons.
//  No UITableView, no UINavigationController, no storyboards, no Auto Layout.
//  v1.x used a UITableViewController inside a UINavigationController and the
//  user could not tap anything; this removes every layer that could swallow a
//  touch or leave the window without a key responder.
//
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface FUSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface FUSMainViewController : UIViewController
@end

@interface FUSEnrollViewController : UIViewController
    <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@end
