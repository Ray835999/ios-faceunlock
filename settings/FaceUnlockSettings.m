//
//  FaceUnlockSettings.m — companion app for FaceUnlock.
//
//  Runs the camera + Vision pipeline (shared FacePrint.m) to capture
//  faceprints, writes templates.plist, and posts a Darwin notification so the
//  SpringBoard tweak hot-reloads the templates.
//

#import "FaceUnlockSettings.h"
#import "FacePrint.h"

#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <notify.h>
#import <unistd.h>

static NSString *const kPrefsAppID    = @"com.ray835999.faceunlock";
static NSString *const kTemplatesChangedNotify =
    @"com.ray835999.faceunlock.templates-changed";

static const NSUInteger    kEnrollSamples  = 5;
static const NSTimeInterval kEnrollCooldown = 1.5;

// ---------------------------------------------------------------------------
// passive diagnostics (v1.2.2)
//
// Symptom class this is built for: "the app opens but no control reacts to
// taps". That splits into exactly three root causes and the log tells them
// apart WITHOUT any user interaction:
//   1. window renders but is NOT key / app never becomes active
//        -> zero sendEvent: lines, snapshot shows key=0
//   2. main thread wedged during launch
//        -> the breadcrumb trail simply stops mid-line
//   3. events arrive but the view tree ignores them
//        -> event lines present, hitTest: returns unexpected classes
// Everything below only observes (+ one force-fix for case 3); when the app is
// healthy it changes nothing except a few log lines.
// ---------------------------------------------------------------------------
static NSString *const kFUDiagDirPath  = @"/var/jb/var/mobile/Library/FaceUnlock";
static NSString *const kFUDiagLogPath  = @"/var/jb/var/mobile/Library/FaceUnlock/ui-diagnostic.log";
static NSString *const kFUDiagFlagPath = @"/var/jb/var/mobile/Library/FaceUnlock/DEBUG_UI";
static const NSUInteger kFUDiagMaxBytes = 128 * 1024;

static NSUInteger g_fuEventCount = 0;   // UIEvents delivered to our window
static NSDate    *g_fuLastEventLog = nil;

static id FUDiagLock(void) {
    static id lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Append one line to the on-device log and NSLog. Never throws, never blocks
// the caller for more than a file append.
static void FUDiagLog(NSString *fmt, ...) {
    @autoreleasepool {
        @try {
            va_list ap;
            va_start(ap, fmt);
            NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
            va_end(ap);
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
            @synchronized (FUDiagLock()) {
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm createDirectoryAtPath:kFUDiagDirPath
                   withIntermediateDirectories:YES attributes:nil error:nil];
                NSDictionary *attr = [fm attributesOfItemAtPath:kFUDiagLogPath error:nil];
                if (attr && [attr[NSFileSize] unsignedIntegerValue] > kFUDiagMaxBytes) {
                    [fm removeItemAtPath:kFUDiagLogPath error:nil];
                }
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kFUDiagLogPath];
                if (!fh) {
                    [fm createFileAtPath:kFUDiagLogPath contents:nil attributes:nil];
                    fh = [NSFileHandle fileHandleForWriting:kFUDiagLogPath];
                }
                if (fh) {
                    @try {
                        [fh seekToEndOfFile];
                        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    } @catch (NSException *e) {}
                    [fh closeFile];
                }
            }
            NSLog(@"[FaceUnlock][diag] %@", msg);
        } @catch (NSException *ex) {}
    }
}

// Window subclass that counts (and throttled-logs) every event it is asked to
// deliver. Zero counted events after the user tapped = the window never
// became key / the app is not active; that is the whole point of this class.
@interface FUDiagnosticWindow : UIWindow
@end

@implementation FUDiagnosticWindow
- (void)sendEvent:(UIEvent *)event {
    [super sendEvent:event];   // diagnostics must never break delivery
    @try {
        if (event.type == UIEventTypeTouches) {
            @synchronized (FUDiagLock()) {
                g_fuEventCount++;
                NSDate *now = [NSDate date];
                if (!g_fuLastEventLog || [now timeIntervalSinceDate:g_fuLastEventLog] > 0.3) {
                    g_fuLastEventLog = now;
                    UITouch *t = event.allTouches.anyObject;
                    FUDiagLog(@"event: touches phase=%ld count=%lu total=%lu",
                              (long)t.phase, (unsigned long)event.allTouches.count,
                              (unsigned long)g_fuEventCount);
                }
            }
        }
    } @catch (NSException *ex) {}
}
@end

static void FUSSetPref(id value, NSString *key) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                          (__bridge CFStringRef)kPrefsAppID,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)kPrefsAppID,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static void FUSPostTemplatesChanged(void) {
    notify_post(kTemplatesChangedNotify.UTF8String);
}

// ---------------------------------------------------------------------------
// app delegate
// ---------------------------------------------------------------------------
@implementation FUSAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    FUDiagLog(@"didFinishLaunching: begin uid=%d screen=%@", (int)getuid(),
              NSStringFromCGRect([UIScreen mainScreen].bounds));
    self.window = [[FUDiagnosticWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    FUSMainViewController *main = [FUSMainViewController new];
    UINavigationController *nav  = [[UINavigationController alloc] initWithRootViewController:main];
    nav.navigationBar.tintColor  = [UIColor colorWithRed:0.35 green:0.68 blue:1.0 alpha:1.0];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    FUDiagLog(@"didFinishLaunching: end window=%p key=%d level=%ld rootVC=%@",
              self.window, (int)self.window.isKeyWindow, (long)self.window.windowLevel,
              NSStringFromClass([nav class]));
    // Passive UI-state snapshot ~1.5s after launch. Needs NO taps, so it works
    // even when every control looks dead; shown on screen only when the
    // DEBUG_UI flag exists (postinst arms it, the alert disarms it).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self diagnosticSnapshot];
    });
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    FUDiagLog(@"applicationDidBecomeActive: state=%ld key=%d events=%lu",
              (long)application.applicationState, (int)self.window.isKeyWindow,
              (unsigned long)g_fuEventCount);
    // A window that renders but lost key status receives NO touches at all -
    // exactly the "everything visible, nothing tappable" symptom. Re-asserting
    // is a no-op when the window is already key.
    if (!self.window.isKeyWindow) {
        FUDiagLog(@"window was NOT key in didBecomeActive - re-asserting makeKeyAndVisible");
        [self.window makeKeyAndVisible];
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    FUDiagLog(@"applicationWillResignActive: state=%ld", (long)application.applicationState);
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    FUDiagLog(@"applicationWillEnterForeground");
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    FUDiagLog(@"applicationDidEnterBackground");
}

#pragma mark - diagnostics
- (void)diagnosticSnapshot {
    @try {
        UIApplication *app  = [UIApplication sharedApplication];
        UIWindow      *w    = self.window;
        UIViewController *root = w.rootViewController;
        CGRect b = [UIScreen mainScreen].bounds;

        // hit-test three representative points: nav bar / middle of the list /
        // bottom of the screen. Which class comes back tells us whether the
        // view tree is where we think it is.
        NSMutableString *hits = [NSMutableString string];
        CGPoint pts[3] = {
            { CGRectGetMidX(b), 60.0 },
            { CGRectGetMidX(b), CGRectGetMidY(b) },
            { CGRectGetMidX(b), CGRectGetMaxY(b) - 120.0 },
        };
        for (int i = 0; i < 3; i++) {
            UIView *v = [w hitTest:pts[i] withEvent:nil];
            [hits appendFormat:@" p%d=%@", i, v ? NSStringFromClass([v class]) : @"nil"];
        }

        FUDiagLog(@"snapshot: state=%ld isKeyWin=%d isKey=%d hidden=%d alpha=%.2f level=%ld bounds=%@ rootVC=%@ events=%lu hits=%@",
                  (long)app.applicationState,
                  (int)(app.keyWindow == w),
                  (int)w.isKeyWindow,
                  (int)w.hidden,
                  (double)w.alpha,
                  (long)w.windowLevel,
                  NSStringFromCGRect(w.bounds),
                  NSStringFromClass([root class]),
                  (unsigned long)g_fuEventCount,
                  hits);

        [self forceInteraction:w];
        [self presentDiagnosticAlertIfFlagged];
    } @catch (NSException *ex) {
        FUDiagLog(@"snapshot exception: %@", ex.reason);
    }
}

// Root cause #3 fallback: if any visible view in the tree somehow ended up
// with userInteractionEnabled == NO, touches die there silently. Log + fix.
- (void)forceInteraction:(UIView *)v {
    if (!v) return;
    @try {
        if (!v.userInteractionEnabled && !v.hidden && v.alpha > 0.01) {
            FUDiagLog(@"force-enabling userInteractionEnabled on %@",
                      NSStringFromClass([v class]));
            v.userInteractionEnabled = YES;
        }
        for (UIView *sub in v.subviews) [self forceInteraction:sub];
    } @catch (NSException *ex) {}
}

- (void)presentDiagnosticAlertIfFlagged {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kFUDiagFlagPath]) return;
    NSString *log = [NSString stringWithContentsOfFile:kFUDiagLogPath
                                              encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSArray<NSString *> *lines = [log componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *tail = [NSMutableArray array];
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0 && (NSUInteger)tail.count < 14; i--) {
        if (lines[i].length) [tail insertObject:lines[i] atIndex:0];
    }
    NSString *msg = [NSString stringWithFormat:@"%@\n\n完整日志：\n%@",
                     [tail componentsJoinedByString:@"\n"], kFUDiagLogPath];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"FaceUnlock 启动诊断（自动弹出）"
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭诊断"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        [[NSFileManager defaultManager] removeItemAtPath:kFUDiagFlagPath error:nil];
        FUDiagLog(@"diagnostic flag removed by user");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    UIViewController *root = self.window.rootViewController;
    if (root) [root presentViewController:alert animated:YES completion:nil];
    FUDiagLog(@"diagnostic alert presented (DEBUG_UI flag)");
}

@end

// ---------------------------------------------------------------------------
// main menu
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, FUSRow) {
    FUSRowStatus = 0,
    FUSRowEnroll,
    FUSRowClear,
    FUSRowEnabled,
    FUSRowThreshold,
};

@implementation FUSMainViewController {
    UISwitch   *_enabledSwitch;
    UILabel    *_statusLabel;
    UILabel    *_thresholdLabel;
    UIStepper  *_thresholdStepper;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    FUDiagLog(@"main: viewDidLoad");
    self.title = @"FaceUnlock";
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    FUDiagLog(@"main: viewDidAppear key=%d delegate=%d dataSource=%d rows=%ld/%ld/%ld",
              (int)self.view.window.isKeyWindow,
              (int)(self.tableView.delegate == self),
              (int)(self.tableView.dataSource == self),
              (long)[self.tableView numberOfRowsInSection:0],
              (long)[self.tableView numberOfRowsInSection:1],
              (long)[self.tableView numberOfRowsInSection:3]);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;   // status
    if (section == 1) return 1;   // enroll
    if (section == 2) return 1;   // clear
    return 2;                     // enabled + threshold
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"状态";
        case 1: return @"录入";
        case 2: return @"数据";
        default: return @"设置";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"录入后，锁屏正脸看前置摄像头即可尝试解锁（阈值内连续 2 帧匹配）。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView  = nil;
    cell.accessoryType  = UITableViewCellAccessoryNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    NSInteger section = indexPath.section;
    NSInteger row     = indexPath.row;

    if (section == 0 && row == FUSRowStatus) {
        NSUInteger n = [FacePrint loadTemplates].count;
        cell.textLabel.text = (n > 0)
            ? [NSString stringWithFormat:@"已录入 %lu 个人脸样本", (unsigned long)n]
            : @"尚未录入人脸";
        cell.textLabel.textColor = (n > 0)
            ? [UIColor labelColor]
            : [UIColor secondaryLabelColor];
    }
    else if (section == 1 && row == FUSRowEnroll) {
        cell.textLabel.text = @"开始录入人脸";
        cell.textLabel.textColor =
            [UIColor colorWithRed:0.35 green:0.68 blue:1.0 alpha:1.0];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else if (section == 2 && row == FUSRowClear) {
        cell.textLabel.text = @"清除所有人脸";
        cell.textLabel.textColor = [UIColor systemRedColor];
    }
    else if (section == 3 && row == FUSRowEnabled) {
        cell.textLabel.text = @"启用 FaceUnlock";
        if (!_enabledSwitch) {
            _enabledSwitch = [UISwitch new];
            CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Enabled"),
                                                            (__bridge CFStringRef)kPrefsAppID);
            BOOL on = (v && (CFGetTypeID(v) == CFBooleanGetTypeID()))
                ? CFBooleanGetValue(v) : YES;
            if (v) CFRelease(v);
            _enabledSwitch.on = on;
            [_enabledSwitch addTarget:self action:@selector(enabledChanged:)
                    forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _enabledSwitch;
    }
    else if (section == 3 && row == FUSRowThreshold) {
        float t = 0.5f;
        CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Threshold"),
                                                        (__bridge CFStringRef)kPrefsAppID);
        if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
            t = [(__bridge NSNumber *)v floatValue];
        }
        if (v) CFRelease(v);
        cell.textLabel.text = @"匹配阈值";
        if (!_thresholdLabel) {
            _thresholdLabel = [UILabel new];
            _thresholdLabel.font = [UIFont systemFontOfSize:15];
            _thresholdLabel.textColor = [UIColor secondaryLabelColor];
            [_thresholdLabel sizeToFit];
        }
        _thresholdLabel.text = [NSString stringWithFormat:@"%.2f", t];
        cell.accessoryView = _thresholdLabel;
        if (!_thresholdStepper) {
            _thresholdStepper = [UIStepper new];
            _thresholdStepper.minimumValue   = 0.20;
            _thresholdStepper.maximumValue   = 0.90;
            _thresholdStepper.stepValue      = 0.05;
            _thresholdStepper.value          = t;
            [_thresholdStepper addTarget:self action:@selector(thresholdChanged:)
                       forControlEvents:UIControlEventValueChanged];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    FUDiagLog(@"main: didSelect section=%ld row=%ld", (long)indexPath.section, (long)indexPath.row);
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == FUSRowEnroll) {
        FUSEnrollViewController *vc = [FUSEnrollViewController new];
        [self.navigationController pushViewController:vc animated:YES];
    }
    else if (indexPath.section == 2 && indexPath.row == FUSRowClear) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"清除所有人脸"
                                                message:@"清除后需要重新录入才能使用人脸解锁。"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"清除"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            [FacePrint deleteTemplates];
            FUSPostTemplatesChanged();
            [self.tableView reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 3 && indexPath.row == FUSRowThreshold) {
        _thresholdStepper.value = _thresholdStepper.value; // tap row = show current value
        [self.tableView reloadData];
    }
}

- (void)enabledChanged:(UISwitch *)sender {
    FUSSetPref(@(sender.on), @"Enabled");
}

- (void)thresholdChanged:(UIStepper *)sender {
    float t = (float)sender.value;
    FUSSetPref(@(t), @"Threshold");
    _thresholdLabel.text = [NSString stringWithFormat:@"%.2f", t];
}

@end

// ---------------------------------------------------------------------------
// enrollment (camera + Vision)
// ---------------------------------------------------------------------------
@implementation FUSEnrollViewController {
    AVCaptureSession        *_session;
    AVCaptureVideoDataOutput *_output;
    dispatch_queue_t         _captureQueue;
    NSMutableArray          *_collected;
    UILabel                 *_statusLabel;
    UILabel                 *_progressLabel;
    UIView                  *_faceGuide;
    UIButton                *_retryButton;
    NSDate                  *_lastCapture;
    BOOL                     _done;
    BOOL                     _cameraTried;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    FUDiagLog(@"enroll: viewDidLoad");
    self.title = @"录入人脸";
    self.view.backgroundColor = [UIColor blackColor];
    _collected = [NSMutableArray array];
    _captureQueue = dispatch_queue_create("com.ray835999.faceunlocksettings.capture",
                                          DISPATCH_QUEUE_SERIAL);

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                     target:self
                                                     action:@selector(cancelTapped)];

    // camera preview (full screen)
    _preview = [AVCaptureVideoPreviewLayer new];
    _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _preview.frame = self.view.bounds;
    [self.view.layer addSublayer:_preview];

    // face guide frame (never a touch target: the guide is decoration only)
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) * 0.55;
    _faceGuide = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    _faceGuide.center = self.view.center;
    _faceGuide.layer.cornerRadius = side / 2;
    _faceGuide.layer.borderColor = [UIColor whiteColor].CGColor;
    _faceGuide.layer.borderWidth = 2.0;
    _faceGuide.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.05];
    _faceGuide.userInteractionEnabled = NO;
    [self.view addSubview:_faceGuide];

    _statusLabel = [UILabel new];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.font = [UIFont boldSystemFontOfSize:17];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.text = @"请正脸对摄像头";
    [self.view addSubview:_statusLabel];

    _progressLabel = [UILabel new];
    _progressLabel.textColor = [UIColor whiteColor];
    _progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:0];
    _progressLabel.textAlignment = NSTextAlignmentCenter;
    _progressLabel.text = [NSString stringWithFormat:@"0 / %lu", (unsigned long)kEnrollSamples];
    [self.view addSubview:_progressLabel];

    _statusLabel.translatesAutoresizingMaskIntoConstraints  = NO;
    _progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:_statusLabel
                                     attribute:NSLayoutAttributeCenterX
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.view
                                     attribute:NSLayoutAttributeCenterX
                                    multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:_statusLabel
                                     attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.view
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1 constant:-48],
        [NSLayoutConstraint constraintWithItem:_progressLabel
                                     attribute:NSLayoutAttributeCenterX
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.view
                                     attribute:NSLayoutAttributeCenterX
                                    multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:_progressLabel
                                     attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:_statusLabel
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1 constant:8],
    ]];

    [self startCamera];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopCamera];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    FUDiagLog(@"enroll: viewDidAppear key=%d events=%lu",
              (int)self.view.window.isKeyWindow, (unsigned long)g_fuEventCount);
}

- (void)dealloc {
    [self stopCamera];
}

- (void)cancelTapped {
    FUDiagLog(@"enroll: cancel tapped");
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - camera failure UX
- (void)failWith:(NSString *)msg {
    FUDiagLog(@"enroll: FAIL %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.text = msg;
        [self showRetryButton];
    });
}

- (void)showRetryButton {
    if (!_retryButton) {
        _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_retryButton setTitle:@"重试打开相机" forState:UIControlStateNormal];
        _retryButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
        _retryButton.layer.cornerRadius = 8;
        _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:_retryButton];
        [NSLayoutConstraint activateConstraints:@[
            [NSLayoutConstraint constraintWithItem:_retryButton
                                         attribute:NSLayoutAttributeCenterX
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:self.view
                                         attribute:NSLayoutAttributeCenterX
                                        multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:_retryButton
                                         attribute:NSLayoutAttributeBottom
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:self.view
                                         attribute:NSLayoutAttributeBottom
                                        multiplier:1 constant:-110],
            [NSLayoutConstraint constraintWithItem:_retryButton
                                         attribute:NSLayoutAttributeWidth
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:nil
                                         attribute:NSLayoutAttributeNotAnAttribute
                                        multiplier:1 constant:200],
            [NSLayoutConstraint constraintWithItem:_retryButton
                                         attribute:NSLayoutAttributeHeight
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:nil
                                         attribute:NSLayoutAttributeNotAnAttribute
                                        multiplier:1 constant:44],
        ]];
        [_retryButton addTarget:self
                         action:@selector(retryTapped)
               forControlEvents:UIControlEventTouchUpInside];
    }
    _retryButton.hidden = NO;
}

- (void)retryTapped {
    FUDiagLog(@"enroll: retry tapped");
    _retryButton.hidden = YES;
    _statusLabel.text = @"正在重新打开相机…";
    [self startCamera];
}

#pragma mark - camera
- (void)startCamera {
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    FUDiagLog(@"enroll: startCamera auth=%ld", (long)status);
    if (status == AVAuthorizationStatusDenied ||
        status == AVAuthorizationStatusRestricted) {
        [self failWith:@"相机权限被拒绝：请到 设置 > 隐私 > 相机 允许 FaceUnlock"];
        return;
    }
    // configure on the main thread (UIKit/AVCaptureSession setup), start on the
    // capture queue so startRunning never blocks the UI
    if (status == AVAuthorizationStatusNotDetermined) {
        // Watchdog: on some rootless setups the TCC prompt never appears and
        // the completion handler never fires. Surface that as a visible error
        // (with a retry button) instead of hanging on a black screen.
        __weak FUSEnrollViewController *wself = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FUSEnrollViewController *s = wself;
            if (s && !s->_cameraTried) {
                [s failWith:@"等待相机授权超时：应用可能被系统静默拒绝，请到 设置 > 隐私 > 相机 允许后点「重试」"];
            }
        });
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) [self configureCamera];
                else [self failWith:@"相机权限未获得：请到 设置 > 隐私 > 相机 允许 FaceUnlock"];
            });
        }];
    } else {
        [self configureCamera];
    }
}

- (void)configureCamera {
    _cameraTried = YES;
    AVCaptureDeviceDiscoverySession *disc =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                              mediaType:AVMediaTypeVideo
                                                               position:AVCaptureDevicePositionFront];
    AVCaptureDevice *cam = disc.devices.firstObject;
    if (!cam) { [self failWith:@"未找到前置摄像头"]; return; }
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
    if (!input) {
        [self failWith:[NSString stringWithFormat:@"摄像头打开失败：%@",
                        err.localizedDescription ?: @"?"]];
        return;
    }
    AVCaptureSession *session = [AVCaptureSession new];
    session.sessionPreset = AVCaptureSessionPreset640x480;
    if (![session canAddInput:input]) { [self failWith:@"摄像头配置失败"]; return; }
    [session addInput:input];

    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.alwaysDiscardsLateVideoFrames = YES;
    out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    [out setSampleBufferDelegate:self queue:_captureQueue];
    if (![session canAddOutput:out]) { [self failWith:@"摄像头配置失败"]; return; }
    [session addOutput:out];
    AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
    if (conn.supportsVideoOrientation) conn.videoOrientation = AVCaptureVideoOrientationPortrait;

    _session = session;
    _output  = out;
    _preview.session = session;
    _retryButton.hidden = YES;
    FUDiagLog(@"enroll: camera configured, starting session");
    dispatch_async(_captureQueue, ^{ [session startRunning]; });
}

- (void)stopCamera {
    AVCaptureSession *session = _session;
    _session = nil;
    _output  = nil;
    if (_preview) _preview.session = nil;
    if (session) {
        // stop on the same queue that started it
        if (_captureQueue) dispatch_async(_captureQueue, ^{ [session stopRunning]; });
        else [session stopRunning];
    }
}

#pragma mark - capture delegate
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        static BOOL firstFrameLogged = NO;
        if (!firstFrameLogged) {
            firstFrameLogged = YES;
            FUDiagLog(@"enroll: first camera frame received");
        }
        @try {
            if (_done || !_session) return;
            NSDate *now = [NSDate date];
            if (_lastCapture && [now timeIntervalSinceDate:_lastCapture] < kEnrollCooldown) return;
            _lastCapture = now;

            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pb) return;

            VNFaceObservation *face = [FacePrint detectFaceInPixelBuffer:pb qualityGate:YES];
            if (!face) {
                [self setStatus:@"看不清人脸，请靠近并对准光线"];
                return;
            }

            VNFeaturePrintObservation *print =
                [FacePrint observationForFace:face pixelBuffer:pb logPrefix:@"settings"];
            if (!print) return;

            NSDictionary *rec = [FacePrint templateForPrint:print];
            @synchronized (_collected) { [_collected addObject:rec]; }

            NSUInteger n = 0;
            @synchronized (_collected) { n = _collected.count; }
            [self setStatus:@"正在录入，请缓慢转头"];
            [self setProgress:n];

            if (n >= kEnrollSamples) {
                _done = YES;
                BOOL ok = [FacePrint saveTemplates:[_collected copy]];
                if (ok) FUSPostTemplatesChanged();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self stopCamera];
                    [self showDoneAndPop:ok];
                });
            }
        } @catch (NSException *ex) {
            NSLog(@"[FaceUnlock] settings capture exception: %@", ex.reason);
            [self setStatus:@"录入出错，请重试"];
        }
    }
}

- (void)setStatus:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.text = text;
    });
}

- (void)setProgress:(NSUInteger)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_progressLabel.text =
            [NSString stringWithFormat:@"%lu / %lu", (unsigned long)n, (unsigned long)kEnrollSamples];
    });
}

- (void)showDoneAndPop:(BOOL)ok {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:ok ? @"录入完成" : @"保存失败"
                                            message:ok
                                            ? @"锁屏后正脸看前置摄像头即可尝试解锁。"
                                            : @"无法写入模板文件，请重试或反馈日志。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
