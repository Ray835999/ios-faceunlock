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

static NSString *const kPrefsAppID    = @"com.ray835999.faceunlock";
static NSString *const kTemplatesChangedNotify =
    @"com.ray835999.faceunlock.templates-changed";

static const NSUInteger    kEnrollSamples  = 5;
static const NSTimeInterval kEnrollCooldown = 1.5;

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
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    FUSMainViewController *main = [FUSMainViewController new];
    UINavigationController *nav  = [[UINavigationController alloc] initWithRootViewController:main];
    nav.navigationBar.tintColor  = [UIColor colorWithRed:0.35 green:0.68 blue:1.0 alpha:1.0];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
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
    self.title = @"FaceUnlock";
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
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
    NSDate                  *_lastCapture;
    BOOL                     _done;
}

- (void)viewDidLoad {
    [super viewDidLoad];
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
    AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:nil];
    preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    preview.frame = self.view.bounds;
    [self.view.layer addSublayer:preview];

    // face guide frame
    CGFloat side = MIN(self.view.bounds.size.width, self.view.bounds.size.height) * 0.55;
    _faceGuide = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    _faceGuide.center = self.view.center;
    _faceGuide.layer.cornerRadius = side / 2;
    _faceGuide.layer.borderColor = [UIColor whiteColor].CGColor;
    _faceGuide.layer.borderWidth = 2.0;
    _faceGuide.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.05];
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

- (void)dealloc {
    [self stopCamera];
}

- (void)cancelTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - camera
- (void)startCamera {
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusDenied ||
        status == AVAuthorizationStatusRestricted) {
        _statusLabel.text = @"相机权限被拒绝：请在 设置 > FaceUnlock 中允许访问相机";
        return;
    }
    void (^configure)(void) = ^{
        AVCaptureDeviceDiscoverySession *disc =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                                  mediaType:AVMediaTypeVideo
                                                                   position:AVCaptureDevicePositionFront];
        AVCaptureDevice *cam = disc.devices.firstObject;
        if (!cam) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = @"未找到前置摄像头";
            });
            return;
        }
        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
        if (!input) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = [NSString stringWithFormat:@"摄像头打开失败：%@",
                                           err.localizedDescription ?: @"?"];
            });
            return;
        }
        AVCaptureSession *session = [AVCaptureSession new];
        session.sessionPreset = AVCaptureSessionPreset640x480;
        if (![session canAddInput:input]) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"摄像头配置失败"; });
            return;
        }
        [session addInput:input];

        AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
        out.alwaysDiscardsLateVideoFrames = YES;
        out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
        [out setSampleBufferDelegate:self queue:self->_captureQueue];
        if (![session canAddOutput:out]) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"摄像头配置失败"; });
            return;
        }
        [session addOutput:out];
        AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
        if (conn.supportsVideoOrientation) conn.videoOrientation = AVCaptureVideoOrientationPortrait;

        self->_session = session;
        self->_output  = out;
        // attach preview layer
        dispatch_async(dispatch_get_main_queue(), ^{
            AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)self.view.layer.sublayers.firstObject;
            preview.session = session;
            [session startRunning];
        });
    };

    if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            if (granted) configure();
            else dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = @"需要相机权限才能录入人脸";
            });
        }];
    } else {
        configure();
    }
}

- (void)stopCamera {
    if (_session) {
        [_session stopRunning];
        _session = nil;
    }
    _output = nil;
}

#pragma mark - capture delegate
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
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
