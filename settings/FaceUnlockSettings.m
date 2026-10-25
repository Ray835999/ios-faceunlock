//
//  FaceUnlockSettings.m — companion app, v2.0.0 (full rewrite)
//
//  Ground rules learned the hard way from v1.x:
//   * no UITableView / UINavigationController (the taps never arrived in v1.2.x)
//   * no Auto Layout, no storyboards — hand-placed frames, one scroll view
//   * every interactive element is a UIButton with an explicit target/action
//   * the screen shows live state instead of asking the user to read logs:
//       - a window-level tap recogniser counts touches and reports what the
//         hit test found, so "touch never reached the app" and "the button is
//         covered by something" are distinguishable at a glance
//       - the tweak's status.plist is rendered verbatim, so camera/authorization
//         /match problems are visible without a console
//
#import "FaceUnlockSettings.h"
#import "FacePrint.h"
#import <notify.h>
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>
#import <math.h>

static NSString *const kDir        = @"/var/jb/var/mobile/Library/FaceUnlock";
static NSString *const kPrefsID    = @"com.ray835999.faceunlock";
static const char *const kNotifyName = "com.ray835999.faceunlock.templates-changed";

static NSString *FUSPath(NSString *n) {
    return [kDir stringByAppendingPathComponent:n];
}

static void FUSLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[FaceUnlockApp] %@", msg);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *p = FUSPath(@"app.log");
        NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
        if (at && [at fileSize] > 64 * 1024) { [fm removeItemAtPath:p error:nil]; at = nil; }
        if (!at) [fm createFileAtPath:p contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) {
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                              [df stringFromDate:[NSDate date]], msg];
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
    }
}

static BOOL FUSPrefBool(NSString *key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kPrefsID);
    if (!v) return def;
    BOOL b = def;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID() || t == CFNumberGetTypeID()) b = [(__bridge NSNumber *)v boolValue];
    CFRelease(v);
    return b;
}

static void FUSPrefSetBool(NSString *key, BOOL value) {
    CFPreferencesSetAppValue((CFStringRef)key,
                             (__bridge CFPropertyListRef)@(value),
                             (CFStringRef)kPrefsID);
    CFPreferencesAppSynchronize((CFStringRef)kPrefsID);
}

// ===========================================================================
#pragma mark - app delegate
// ===========================================================================
@implementation FUSAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    FUSLog(@"didFinishLaunching begin");
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    FUSMainViewController *root = [FUSMainViewController new];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    FUSLog(@"didFinishLaunching end: window=%@ frame=%@ key=%d",
           NSStringFromClass([self.window class]),
           NSStringFromCGRect(self.window.bounds),
           (int)self.window.isKeyWindow);
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Re-assert key-window status: if a system alert or another window stole key
    // status, every touch would go to that window instead of ours — one of the
    // ways an app looks like "all buttons dead".
    if (self.window && !self.window.isKeyWindow) {
        FUSLog(@"window lost key status - reclaiming");
        [self.window makeKeyAndVisible];
    }
}

@end

// ===========================================================================
#pragma mark - main screen
// ===========================================================================
@interface FUSMainViewController () <UIGestureRecognizerDelegate>
@end

@implementation FUSMainViewController {
    UIScrollView *_scroll;
    UILabel      *_titleLabel;
    UILabel      *_versionLabel;
    UIView       *_card;
    UILabel      *_statusLabel;
    UIView       *_switchRow;
    UILabel      *_switchLabel;
    UISwitch     *_enabledSwitch;
    UIButton     *_enrollButton;
    UIButton     *_deleteButton;
    UIButton     *_refreshButton;
    UIButton     *_copyButton;
    UIButton     *_panicButton;
    UILabel      *_touchLabel;
    UILabel      *_pathsLabel;
    NSUInteger    _touchCount;
    NSTimer      *_timer;
    CGSize        _lastLayoutSize;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:1.0];
    FUSLog(@"main viewDidLoad");

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _titleLabel = [self label:@"FaceUnlock" size:26 weight:UIFontWeightBold
                        color:[UIColor whiteColor]];
    [_scroll addSubview:_titleLabel];

    _versionLabel = [self label:@"v2.2.0 · 采集阶梯版" size:12 weight:UIFontWeightRegular
                          color:[UIColor colorWithWhite:0.6 alpha:1]];
    [_scroll addSubview:_versionLabel];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    _card.layer.cornerRadius = 10;
    [_scroll addSubview:_card];

    _statusLabel = [self label:@"" size:11 weight:UIFontWeightRegular
                         color:[UIColor colorWithRed:0.7 green:0.9 blue:0.75 alpha:1]];
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 0;
    [_card addSubview:_statusLabel];

    _switchRow = [[UIView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:_switchRow];
    _switchLabel = [self label:@"启用锁屏人脸解锁" size:16 weight:UIFontWeightMedium
                         color:[UIColor whiteColor]];
    [_switchRow addSubview:_switchLabel];
    _enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _enabledSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.75 blue:0.45 alpha:1];
    [_enabledSwitch addTarget:self action:@selector(enabledChanged:)
             forControlEvents:UIControlEventValueChanged];
    [_switchRow addSubview:_enabledSwitch];

    _enrollButton  = [self button:@"① 开始录入人脸"
                            color:[UIColor colorWithRed:0.13 green:0.62 blue:0.38 alpha:1]
                           action:@selector(enrollTapped:)];
    _deleteButton  = [self button:@"删除已录入的人脸数据"
                            color:[UIColor colorWithWhite:0.25 alpha:1]
                           action:@selector(deleteTapped:)];
    _refreshButton = [self button:@"刷新状态"
                            color:[UIColor colorWithWhite:0.22 alpha:1]
                           action:@selector(refreshTapped:)];
    _copyButton    = [self button:@"复制诊断信息（可粘贴发给我）"
                            color:[UIColor colorWithWhite:0.22 alpha:1]
                           action:@selector(copyTapped:)];
    _panicButton   = [self button:@"② 急停：立即禁用并解除卡死"
                            color:[UIColor colorWithRed:0.68 green:0.16 blue:0.16 alpha:1]
                           action:@selector(panicTapped:)];
    for (UIButton *b in @[_enrollButton, _deleteButton, _refreshButton,
                          _copyButton, _panicButton]) {
        [_scroll addSubview:b];
    }

    _touchLabel = [self label:@"触摸事件：0" size:11 weight:UIFontWeightRegular
                        color:[UIColor colorWithWhite:0.55 alpha:1]];
    _touchLabel.numberOfLines = 0;
    [_scroll addSubview:_touchLabel];

    _pathsLabel = [self label:[NSString stringWithFormat:@"数据目录 %@", kDir]
                         size:10 weight:UIFontWeightRegular
                        color:[UIColor colorWithWhite:0.42 alpha:1]];
    _pathsLabel.numberOfLines = 0;
    [_scroll addSubview:_pathsLabel];

    // Fallback tap observer. cancelsTouchesInView = NO so buttons still work.
    // If this counter does not move while the user taps, the touches are not
    // reaching the app process at all; if it moves but a button does nothing,
    // the hit-test line tells us what is covering the button.
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(anyTap:)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    [self refreshStatus];

    __weak FUSMainViewController *weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        FUSMainViewController *ss = weakSelf;
        if (!ss) { [t invalidate]; return; }
        if (ss.view.window == nil) return;
        [ss refreshStatus];
    }];
    FUSLog(@"main viewDidLoad done");
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    FUSLog(@"main viewDidAppear: bounds=%@ window=%@",
           NSStringFromCGRect(self.view.bounds), self.view.window ? @"yes" : @"nil");
    [self refreshStatus];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(size, _lastLayoutSize)) return;
    _lastLayoutSize = size;
    [self layoutContents];
}

#pragma mark - ui helpers
- (UILabel *)label:(NSString *)text size:(CGFloat)size
            weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (UIButton *)button:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = color;
    b.layer.cornerRadius = 10;
    b.exclusiveTouch = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)layoutContents {
    CGFloat margin = 16;
    CGFloat w = self.view.bounds.size.width;
    CGFloat cw = w - margin * 2;
    CGFloat y = 8;

    _scroll.frame = self.view.bounds;

    if (@available(iOS 11.0, *)) {
        if (self.view.safeAreaInsets.top > 0) y = self.view.safeAreaInsets.top - 4;
    }

    _titleLabel.frame = CGRectMake(margin, y, cw, 34);
    y += 34;
    _versionLabel.frame = CGRectMake(margin, y, cw, 16);
    y += 28;

    CGSize statusSize = [_statusLabel sizeThatFits:CGSizeMake(cw - 24, CGFLOAT_MAX)];
    CGFloat textH = MAX(statusSize.height, 20);
    CGFloat cardH = textH + 24;
    _card.frame = CGRectMake(margin, y, cw, cardH);
    _statusLabel.frame = CGRectMake(12, 12, cw - 24, textH);
    y += cardH + 14;

    _switchRow.frame = CGRectMake(margin, y, cw, 40);
    _switchLabel.frame = CGRectMake(0, 0, cw - 70, 40);
    _enabledSwitch.frame = CGRectMake(cw - 51, 5, 51, 31);
    y += 52;

    _enrollButton.frame  = CGRectMake(margin, y, cw, 56); y += 66;
    _deleteButton.frame  = CGRectMake(margin, y, cw, 44); y += 54;
    _refreshButton.frame = CGRectMake(margin, y, cw, 44); y += 54;
    _copyButton.frame    = CGRectMake(margin, y, cw, 44); y += 54;
    _panicButton.frame   = CGRectMake(margin, y, cw, 44); y += 58;

    CGSize touchSize = [_touchLabel sizeThatFits:CGSizeMake(cw, CGFLOAT_MAX)];
    CGFloat touchH = MAX(touchSize.height, 18);
    _touchLabel.frame = CGRectMake(margin, y, cw, touchH);
    y += touchH + 8;

    CGSize pathSize = [_pathsLabel sizeThatFits:CGSizeMake(cw, CGFLOAT_MAX)];
    CGFloat pathH = MAX(pathSize.height, 14);
    _pathsLabel.frame = CGRectMake(margin, y, cw, pathH);
    y += pathH + 40;

    _scroll.contentSize = CGSizeMake(w, y);
}

#pragma mark - status
- (NSString *)statusText {
    NSMutableString *s = [NSMutableString string];

    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FUSPath(@"status.plist")];
    BOOL killed = [[NSFileManager defaultManager] fileExistsAtPath:FUSPath(@"DISABLED")];
    NSUInteger templates = [FacePrint loadTemplates].count;

    [s appendFormat:@"已录入模板 : %lu\n", (unsigned long)templates];
    [s appendFormat:@"开关状态   : %@\n", FUSPrefBool(@"Enabled", YES) ? @"启用" : @"禁用"];
    [s appendFormat:@"急停开关   : %@\n", killed ? @"已禁用 (DISABLED)" : @"未触发"];

    if (!st) {
        [s appendString:@"插件遥测   : 无（插件尚未在 SpringBoard 中运行）"];
        return s;
    }

    NSDate *upd = st[@"updated"];
    double age = upd ? -[upd timeIntervalSinceNow] : -1;
    [s appendFormat:@"插件遥测   : %.0f 秒前更新\n", age];
    [s appendFormat:@"插件版本   : %@  系统 %@\n", st[@"version"] ?: @"?", st[@"device"] ?: @"?"];
    [s appendFormat:@"当前状态   : %@\n", st[@"state"] ?: @"?"];
    [s appendFormat:@"Vision/AVF : %@ / %@\n",
        [st[@"visionOK"] boolValue] ? @"OK" : @"NO",
        [st[@"avOK"] boolValue] ? @"OK" : @"NO"];
    if (st[@"cameraAuth"]) {
        NSArray *names = @[@"未询问", @"受限", @"被拒绝", @"已授权"];
        NSInteger a = [st[@"cameraAuth"] integerValue];
        [s appendFormat:@"SB相机权限 : %@ (%ld)\n",
            (a >= 0 && a < (NSInteger)names.count) ? names[a] : @"?", (long)a];
    }
    [s appendFormat:@"会话/帧/脸 : %@ / %@ / %@\n",
        st[@"sessions"] ?: @0, st[@"frames"] ?: @0, st[@"faces"] ?: @0];
    if (st[@"orientation"])
        [s appendFormat:@"检测方向   : %@\n", st[@"orientation"]];
    if (st[@"lastDistance"])
        [s appendFormat:@"最近距离   : %.3f\n", [st[@"lastDistance"] floatValue]];
    if (st[@"cameraFailures"])
        [s appendFormat:@"相机失败   : %@ 次\n", st[@"cameraFailures"]];
    if (st[@"unlockPath"])
        [s appendFormat:@"解锁路径   : %@\n", st[@"unlockPath"]];
    if (st[@"stillLockedAfterUnlock"])
        [s appendFormat:@"解锁结果   : %@\n",
            [st[@"stillLockedAfterUnlock"] boolValue] ? @"仍锁屏(失败)" : @"已解开(成功)"];
    if (st[@"lastError"])
        [s appendFormat:@"最近错误   : %@\n", st[@"lastError"]];
    if (st[@"lockScreenVC"])
        [s appendFormat:@"锁屏VC类   : %@\n", st[@"lockScreenVC"]];
    return s;
}

- (void)refreshStatus {
    _statusLabel.text = [self statusText];
    _enabledSwitch.on = FUSPrefBool(@"Enabled", YES) &&
        ![[NSFileManager defaultManager] fileExistsAtPath:FUSPath(@"DISABLED")];
    [self layoutContents];
}

#pragma mark - actions
- (void)anyTap:(UITapGestureRecognizer *)g {
    _touchCount++;
    CGPoint p = [g locationInView:self.view];
    UIView *hit = [self.view hitTest:p withEvent:nil];
    NSString *hitName = hit ? NSStringFromClass([hit class]) : @"nil";
    if ([hit isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)hit titleForState:UIControlStateNormal];
        hitName = [NSString stringWithFormat:@"UIButton(%@)", t ?: @"?"];
    }
    _touchLabel.text = [NSString stringWithFormat:
        @"触摸事件：%lu 次\n命中视图：%@ @ (%.0f,%.0f)",
        (unsigned long)_touchCount, hitName, p.x, p.y];
    FUSLog(@"tap #%lu at (%.0f,%.0f) hit=%@", (unsigned long)_touchCount, p.x, p.y, hitName);
}

- (void)enabledChanged:(UISwitch *)sw {
    FUSLog(@"switch -> %d", (int)sw.isOn);
    FUSPrefSetBool(@"Enabled", sw.isOn);
    if (sw.isOn) {
        [[NSFileManager defaultManager] removeItemAtPath:FUSPath(@"DISABLED") error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:FUSPath(@"boot.plist") error:nil];
    } else {
        [@"disabled from app by user" writeToFile:FUSPath(@"DISABLED")
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding error:nil];
    }
    [self refreshStatus];
}

- (void)enrollTapped:(UIButton *)b {
    FUSLog(@"enroll tapped");
    FUSEnrollViewController *vc = [FUSEnrollViewController new];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:vc animated:YES completion:^{
        FUSLog(@"enroll presented");
    }];
}

- (void)deleteTapped:(UIButton *)b {
    FUSLog(@"delete tapped");
    [FacePrint deleteTemplates];
    notify_post(kNotifyName);
    [self refreshStatus];
    [self toast:@"已删除所有人脸数据"];
}

- (void)refreshTapped:(UIButton *)b {
    FUSLog(@"refresh tapped");
    [self refreshStatus];
    [self toast:@"已刷新"];
}

- (void)copyTapped:(UIButton *)b {
    NSMutableString *dump = [NSMutableString string];
    [dump appendString:@"==== FaceUnlock 诊断 ====\n"];
    [dump appendString:[self statusText]];
    for (NSString *f in @[@"tweak.log", @"app.log"]) {
        NSString *txt = [NSString stringWithContentsOfFile:FUSPath(f)
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (txt.length > 4000) txt = [txt substringFromIndex:txt.length - 4000];
        [dump appendFormat:@"\n---- %@ ----\n%@\n", f, txt ?: @"(空)"];
    }
    [UIPasteboard generalPasteboard].string = dump;
    [self toast:@"诊断信息已复制到剪贴板"];
}

- (void)panicTapped:(UIButton *)b {
    FUSLog(@"PANIC tapped - disabling tweak");
    [@"disabled from app (panic button)" writeToFile:FUSPath(@"DISABLED")
                                          atomically:YES
                                            encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:FUSPath(@"boot.plist") error:nil];
    [self refreshStatus];
    [self toast:@"已急停：插件已禁用，重启后也不会加载。\n要恢复请把上方开关重新打开。"];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"FaceUnlock"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

// ===========================================================================
#pragma mark - enrollment
// ===========================================================================
static const NSUInteger kSamples = 5;

// ---------------------------------------------------------------------------
//  v2.2.0 — "preview is live but 帧 0" post-mortem
//
//  The screenshot that triggered this rewrite showed a perfectly live camera
//  preview with a face inside the guide circle and a readout of 帧 0 · 检测 0.
//  A running session that renders into AVCaptureVideoPreviewLayer but hands the
//  AVCaptureVideoDataOutput zero buffers is not a Vision problem and not a
//  permission problem: the preview connection and the data-output connection
//  negotiate *separately*, and the data connection dies silently when
//  videoSettings asks for a pixel format the connection cannot actually
//  produce.  32BGRA is listed in availableVideoCVPixelFormatTypes on several
//  older front cameras yet never flows — and it was the only format we asked
//  for, on a session that had already been committed (i.e. the setting was
//  applied to a live connection).
//
//  So the capture layer is rebuilt around three rules:
//    1. videoSettings is set BEFORE addOutput:, never after commit.
//    2. The native bi-planar formats (420f / 420v) are tried before BGRA.
//    3. Every configuration is a fresh session, and a session that produces no
//       frame within 2 s is torn down automatically and replaced by the next
//       candidate — no user action.
//  After the video ladder: a still-photo session (photo output only), and
//  finally the system camera UI (UIImagePickerController), which cannot fail
//  because it is Apple's own pipeline.  All four paths feed the same
//  processPixelBuffer: so the saved templates stay byte-compatible.
// ---------------------------------------------------------------------------

static NSString *FUSFormatName(OSType f) {
    switch (f) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  return @"420f";
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return @"420v";
        case kCVPixelFormatType_32BGRA:                       return @"BGRA";
        default: return [NSString stringWithFormat:@"0x%08x", (unsigned)f];
    }
}

static const NSUInteger kVideoAttempts = 4;

static OSType FUSFormatForAttempt(NSUInteger i) {
    switch (i) {
        case 0:  return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        case 1:  return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        case 2:  return kCVPixelFormatType_32BGRA;
        default: return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }
}

// last attempt repeats 420f but with a different preset, so a preset-related
// negotiation failure is covered as well
static NSString *FUSPresetForAttempt(NSUInteger i) {
    return (i >= 3) ? AVCaptureSessionPresetHigh : AVCaptureSessionPreset640x480;
}

// UIImage (system camera) -> BGRA CVPixelBuffer, uniformly scaled so the face
// geometry stays comparable with the live frames.  BGRA is always accepted by
// Vision for still images; only the *streaming* connection was picky.
static CVPixelBufferRef FUSPixelBufferFromImage(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return NULL;

    double scale = 960.0 / (double)MAX(w, h);
    if (scale > 1.0) scale = 1.0;
    size_t dw = (size_t)llround((double)w * scale);
    size_t dh = (size_t)llround((double)h * scale);
    if (dw < 2 || dh < 2) return NULL;

    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                             (id)kCVPixelBufferPixelFormatTypeKey :
                                 @(kCVPixelFormatType_32BGRA) };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, dw, dh,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return NULL;
    }

    static CIContext *ctx = nil;
    if (!ctx) ctx = [CIContext contextWithOptions:nil];
    CIImage *ci = [CIImage imageWithCGImage:cg];
    CGFloat sx = (CGFloat)dw / ci.extent.size.width;
    CGFloat sy = (CGFloat)dh / ci.extent.size.height;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [ctx render:ci
        toCVPixelBuffer:pb
                 bounds:CGRectMake(0, 0, dw, dh)
             colorSpace:cs];
    CGColorSpaceRelease(cs);
    return pb;
}

@interface FUSEnrollViewController () <UIImagePickerControllerDelegate,
                                       UINavigationControllerDelegate>
@end

@implementation FUSEnrollViewController {
    AVCaptureSession         *_session;
    AVCaptureVideoDataOutput *_output;
    AVCapturePhotoOutput     *_photoOut;

    // Two queues on purpose: session configuration/start/stop and the sample
    // buffer callbacks must never share a queue.  startRunning() blocks, and
    // when it runs on the delegate queue the first frames are starved for as
    // long as it takes — or for good, if the session then needs a teardown.
    dispatch_queue_t          _sessionQueue;
    dispatch_queue_t          _queue;

    NSMutableArray           *_collected;
    UIView                   *_guide;
    UILabel                  *_hintLabel;
    UILabel                  *_progressLabel;
    UILabel                  *_meterLabel;
    UIButton                 *_cancelButton;
    UIButton                 *_retryButton;
    UIButton                 *_manualButton;

    NSDate                   *_lastCapture;
    NSDate                   *_lastMeter;
    NSTimer                  *_photoTimer;

    NSUInteger                _framesSeen;
    NSUInteger                _framesAtStart;   // frames already seen when this rung began
    NSUInteger                _detectRuns;
    NSUInteger                _faceHits;
    NSUInteger                _bufW;
    NSUInteger                _bufH;
    NSUInteger                _dropsSeen;
    NSUInteger                _photoShots;
    NSUInteger                _attempt;      // current rung of the ladder
    unsigned int              _chosenFmt;
    NSString                 *_sourceNote;   // 源 视频420f / 照片 / 系统相机
    NSString                 *_linkNote;     // conn/act/run state of the session
    float                     _lastQuality;

    BOOL                      _finished;
    BOOL                      _cameraConfigured;
    BOOL                      _permissionResolved;
    BOOL                      _photoMode;    // still-image session in use
    BOOL                      _photoInFlight;
    BOOL                      _manualMode;   // system camera UI in use
}

- (void)viewDidLoad {
    [super viewDidLoad];
    FUSLog(@"enroll viewDidLoad (v2.2.0 capture ladder)");
    self.view.backgroundColor = [UIColor blackColor];
    _collected = [NSMutableArray array];
    _queue = dispatch_queue_create("com.ray835999.faceunlock.enroll", DISPATCH_QUEUE_SERIAL);
    _sessionQueue = dispatch_queue_create("com.ray835999.faceunlock.session",
                                          DISPATCH_QUEUE_SERIAL);
    _sourceNote = @"等待相机";
    _linkNote   = @"-";

    _preview = [AVCaptureVideoPreviewLayer new];
    _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _preview.frame = self.view.bounds;
    [self.view.layer addSublayer:_preview];

    _guide = [[UIView alloc] initWithFrame:CGRectZero];
    _guide.userInteractionEnabled = NO;          // decoration only: never eats a touch
    _guide.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    _guide.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    _guide.layer.borderWidth = 2.0;
    [self.view addSubview:_guide];

    _hintLabel = [self label:@"正在准备相机…" size:15 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 0;
    [self.view addSubview:_hintLabel];

    _progressLabel = [self label:@"0 / 5" size:15 weight:UIFontWeightBold];
    _progressLabel.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.6 alpha:1];
    _progressLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_progressLabel];

    // Three lines of monospaced text. A screenshot of this block is the whole
    // diagnosis:
    //   line 1  counters + which rung of the ladder is running
    //   line 2  where the frames come from and in which pixel format
    //   line 3  the session connection state + where detection stopped
    _meterLabel = [self label:@"帧 0 · 检测 0 · 命中 0" size:10 weight:UIFontWeightRegular];
    _meterLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _meterLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    _meterLabel.textAlignment = NSTextAlignmentCenter;
    _meterLabel.numberOfLines = 0;
    [self.view addSubview:_meterLabel];

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    [_cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _cancelButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _cancelButton.layer.cornerRadius = 9;
    _cancelButton.exclusiveTouch = YES;
    [_cancelButton addTarget:self action:@selector(cancelTapped:)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_cancelButton];

    // Always available: the system camera UI cannot be starved the way an
    // AVCaptureSession can, so enrollment is possible even when every
    // programmatic path fails.
    _manualButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_manualButton setTitle:@"系统相机拍照" forState:UIControlStateNormal];
    [_manualButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _manualButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _manualButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    _manualButton.layer.cornerRadius = 8;
    _manualButton.exclusiveTouch = YES;
    [_manualButton addTarget:self action:@selector(manualTapped:)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_manualButton];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_retryButton setTitle:@"重试打开相机" forState:UIControlStateNormal];
    [_retryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _retryButton.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.85 alpha:1];
    _retryButton.layer.cornerRadius = 10;
    _retryButton.exclusiveTouch = YES;
    _retryButton.hidden = YES;
    [_retryButton addTarget:self action:@selector(retryTapped:)
           forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_retryButton];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) insets = self.view.safeAreaInsets;

    _preview.frame = self.view.bounds;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat side = MIN(w, h) * 0.54;
    _guide.frame = CGRectMake((w - side) / 2, (h - side) / 2 + 10, side, side);
    _guide.layer.cornerRadius = side / 2;

    CGFloat meterH = 62;
    CGFloat meterY = h - insets.bottom - 8 - meterH;
    // retry and the system-camera escape hatch share one row directly above
    // the meter, so the block never collides with the guide circle on a 4"
    // screen either
    CGFloat rowH = 44;
    CGFloat rowY = meterY - 8 - rowH;

    _cancelButton.frame  = CGRectMake(insets.left + 16, insets.top + 8, 68, 38);
    _progressLabel.frame = CGRectMake(16, insets.top + 12, w - 32, 30);
    _hintLabel.frame     = CGRectMake(24, CGRectGetMaxY(_guide.frame) + 10, w - 48,
                                      MAX(30, rowY - CGRectGetMaxY(_guide.frame) - 20));
    _retryButton.frame   = CGRectMake(w - insets.right - 12 - 104, rowY, 104, rowH);
    _manualButton.frame  = CGRectMake(insets.left + 12, rowY,
                                      w - insets.left - insets.right - 24 - 104 - 8, rowH);
    _meterLabel.frame    = CGRectMake(10, meterY, w - 20, meterH);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    FUSLog(@"enroll viewDidAppear (manual=%d)", (int)_manualMode);
    if (_manualMode) return;   // the picker dismisses/presents us repeatedly
    [self startCamera];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (_manualMode) return;   // do not tear the picker flow down
    [self stopCamera];
}

#pragma mark - camera: authorization

- (void)startCamera {
    if (_cameraConfigured || _manualMode) return;

    // If Vision itself is not usable in this process, say so immediately
    // instead of leaving the user staring at a live preview that can never
    // produce a sample.
    if (![FacePrint visionAvailable]) {
        FUSLog(@"Vision unavailable in the app process");
        [self failWith:@"Vision 不可用：这台设备上无法做人脸检测。\n这是环境问题，不是操作问题。"];
        return;
    }

    _hintLabel.text = @"正在检查相机权限…";

    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    FUSLog(@"camera auth status = %ld", (long)st);

    if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted) {
        [self failWith:@"相机权限被拒绝。\n请到 设置 → 隐私 → 相机 里允许 FaceUnlock。"];
        return;
    }
    if (st == AVAuthorizationStatusNotDetermined) {
        _hintLabel.text = @"请允许访问相机";
        // watchdog: on some jailbreak setups the TCC prompt never appears and the
        // completion handler never fires — never wait forever
        __weak FUSEnrollViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FUSEnrollViewController *ss = weakSelf;
            if (!ss) return;
            if (!ss->_permissionResolved && !ss->_cameraConfigured && !ss->_finished) {
                FUSLog(@"permission prompt never answered");
                [ss failWith:@"相机权限弹窗没有响应。\n请到 设置 → 隐私 → 相机 里手动允许 FaceUnlock，然后点重试。"];
            }
        });
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FUSEnrollViewController *ss = weakSelf;
                if (!ss) return;
                ss->_permissionResolved = YES;
                FUSLog(@"permission granted=%d", (int)granted);
                if (granted) [ss beginAttempt:0];
                else [ss failWith:@"需要相机权限才能录入人脸。\n请到 设置 → 隐私 → 相机 里允许 FaceUnlock。"];
            });
        }];
        return;
    }
    [self beginAttempt:0];
}

#pragma mark - camera: the video ladder

// Advance the ladder. Each rung is a brand-new session; the previous one is
// torn down (and stopped on the session queue) before the next is built, so
// the two never fight over the camera.
- (void)beginAttempt:(NSUInteger)i {
    if (_finished || _manualMode) return;
    _attempt = i;

    if (i >= kVideoAttempts) {          // video is dead -> stills
        [self switchToPhotoMode];
        return;
    }

    [self teardownSession];
    // never reset _framesSeen: a frame from the previous rung could still be in
    // flight, and a bogus 1 would make the watchdog think this rung works
    _framesAtStart = _framesSeen;
    OSType fmt  = FUSFormatForAttempt(i);
    _chosenFmt  = fmt;
    _sourceNote = [NSString stringWithFormat:@"视频 %@", FUSFormatName(fmt)];
    _linkNote   = @"building";
    [self setHint:[NSString stringWithFormat:
        @"正在打开相机（第 %lu/%lu 种格式：%@）",
        (unsigned long)(i + 1), (unsigned long)kVideoAttempts, FUSFormatName(fmt)]];
    [self publishMeter];

    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        [weakSelf buildVideoSession:i];
    });
}

// runs on _sessionQueue
- (void)buildVideoSession:(NSUInteger)i {
    @autoreleasepool {
        @try {
            AVCaptureDeviceDiscoverySession *disc =
                [AVCaptureDeviceDiscoverySession
                    discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                          mediaType:AVMediaTypeVideo
                                           position:AVCaptureDevicePositionFront];
            AVCaptureDevice *cam = disc.devices.firstObject;
            if (!cam) { [self uiFail:@"没有找到前置摄像头"]; return; }

            NSError *err = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
            if (!input) {
                [self uiFail:[NSString stringWithFormat:@"打开摄像头失败：%@",
                              err.localizedDescription ?: @"未知错误"]];
                return;
            }

            OSType fmt = FUSFormatForAttempt(i);
            AVCaptureSession *session = [AVCaptureSession new];
            AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
            out.alwaysDiscardsLateVideoFrames = YES;
            // RULE 1: videoSettings BEFORE addOutput:. Applying it to an output
            // that is already part of a committed session is not honoured by
            // every AVFoundation build — the connection then stays mute while
            // the preview keeps rendering.
            out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(fmt) };

            [session beginConfiguration];
            NSString *preset = FUSPresetForAttempt(i);
            if ([session canSetSessionPreset:preset]) session.sessionPreset = preset;
            if (![session canAddInput:input]) {
                [session commitConfiguration];
                [self uiFail:@"无法添加相机输入"];
                return;
            }
            [session addInput:input];
            if (![session canAddOutput:out]) {
                [session commitConfiguration];
                [self uiFail:@"无法添加视频输出"];
                return;
            }
            [session addOutput:out];
            [session commitConfiguration];

            [out setSampleBufferDelegate:self queue:_queue];

            AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
            if (conn) {
                conn.enabled = YES;
                if (conn.supportsVideoOrientation) {
                    conn.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
            }
            NSArray *avail = out.availableVideoCVPixelFormatTypes;
            BOOL listed = [avail containsObject:@(fmt)];

            NSString *pname = session.sessionPreset ?: @"?";
            pname = [pname stringByReplacingOccurrencesOfString:@"AVCaptureSessionPreset"
                                                     withString:@""];
            NSString *link = [NSString stringWithFormat:
                @"out%lu conn%@ act%@ en%@ fmt%@%@",
                (unsigned long)session.outputs.count,
                conn ? @"1" : @"0",
                (conn && conn.isActive) ? @"1" : @"0",
                (conn && conn.enabled)  ? @"1" : @"0",
                listed ? @"!" : @"?",
                pname];
            FUSLog(@"attempt %lu: fmt=%@ preset=%@ avail=%@ %@",
                   (unsigned long)i, FUSFormatName(fmt), session.sessionPreset, avail, link);

            _session = session;
            _output  = out;
            _photoOut = nil;
            _linkNote = link;

            dispatch_async(dispatch_get_main_queue(), ^{
                self->_preview.session = session;
                self->_cameraConfigured = YES;
                self->_retryButton.hidden = YES;
                self->_hintLabel.text = @"把脸放进圆圈里，保持不动";
                [self publishMeter];
            });

            // already on the session queue: startRunning may block here freely
            @try { [session startRunning]; }
            @catch (NSException *e) { FUSLog(@"startRunning: %@", e.reason); }
            FUSLog(@"attempt %lu isRunning=%d inter=%d", (unsigned long)i,
                   (int)session.isRunning, (int)session.isInterrupted);

            AVCaptureConnection *c2 = [out connectionWithMediaType:AVMediaTypeVideo];
            _linkNote = [NSString stringWithFormat:@"run%@ act%@ en%@",
                         session.isRunning ? @"1" : @"0",
                         (c2 && c2.isActive) ? @"1" : @"0",
                         (c2 && c2.enabled)  ? @"1" : @"0"];

            // RULE 3: no frame in 2 s -> next rung, automatically.
            NSUInteger rung = i;
            __weak FUSEnrollViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FUSEnrollViewController *ss = weakSelf;
                if (!ss || ss->_finished || ss->_manualMode) return;
                if (ss->_attempt != rung) return;
                if (ss->_framesSeen > ss->_framesAtStart) return;
                FUSLog(@"attempt %lu delivered 0 frames -> next candidate", (unsigned long)rung);
                [ss beginAttempt:rung + 1];
            });
        } @catch (NSException *e) {
            FUSLog(@"buildVideoSession exception: %@", e.reason);
            [self uiFail:[NSString stringWithFormat:@"相机初始化异常：%@", e.reason ?: @"?"]];
        }
    }
}

- (void)uiFail:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{ [self failWith:msg]; });
}

- (void)teardownSession {
    AVCaptureSession *s = _session;
    _session = nil;
    _output  = nil;
    _photoOut = nil;
    _cameraConfigured = NO;
    _photoInFlight = NO;
    if (s) {
        // stopRunning blocks as well: same serial queue as startRunning, so it
        // is ordered behind whatever the previous rung was doing
        dispatch_async(_sessionQueue, ^{
            @autoreleasepool {
                @try { [s stopRunning]; } @catch (NSException *e) {}
            }
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_preview.session == s) self->_preview.session = nil;
    });
}

#pragma mark - camera: still-photo rung

// The streamed buffers never came. Stills go through a different path inside
// AVFoundation (on-demand capture rather than a continuous tap), so they work
// in setups where the stream is mute. Its own session, preview + photo output
// only — no competing video data output.
- (void)switchToPhotoMode {
    if (_photoMode || _finished || _manualMode) return;
    _photoMode = YES;
    _framesAtStart = _framesSeen;
    _photoShots = 0;
    _sourceNote = @"照片";
    _linkNote   = @"building";
    [self setHint:@"视频流取不到帧，已改用拍照识别…"];
    [self publishMeter];

    // the video session must be gone before the still session starts, or the
    // two will fight over the camera
    [self teardownSession];

    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        @autoreleasepool {
            @try {
                AVCaptureDeviceDiscoverySession *disc =
                    [AVCaptureDeviceDiscoverySession
                        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                              mediaType:AVMediaTypeVideo
                                               position:AVCaptureDevicePositionFront];
                AVCaptureDevice *cam = disc.devices.firstObject;
                NSError *err = nil;
                AVCaptureDeviceInput *input = cam ? [AVCaptureDeviceInput deviceInputWithDevice:cam
                                                                                         error:&err] : nil;
                AVCaptureSession *session = [AVCaptureSession new];
                AVCapturePhotoOutput *photoOut = [AVCapturePhotoOutput new];

                [session beginConfiguration];
                if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
                    session.sessionPreset = AVCaptureSessionPreset640x480;
                }
                if (!input || ![session canAddInput:input]) {
                    [session commitConfiguration];
                    [self uiFail:@"拍照模式也拿不到相机"];
                    return;
                }
                [session addInput:input];
                if (![session canAddOutput:photoOut]) {
                    [session commitConfiguration];
                    FUSLog(@"photo output rejected -> manual camera only");
                    [self uiManualOnly];
                    return;
                }
                [session addOutput:photoOut];
                [session commitConfiguration];

                self->_session = session;
                self->_photoOut = photoOut;
                self->_output = nil;
                self->_linkNote = @"photo session";

                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_preview.session = session;
                    self->_cameraConfigured = YES;
                    self->_hintLabel.text = @"正在拍照识别…";
                    [self publishMeter];
                });

                @try { [session startRunning]; }
                @catch (NSException *e) { FUSLog(@"photo startRunning: %@", e.reason); }

                dispatch_async(dispatch_get_main_queue(), ^{
                    FUSEnrollViewController *ss = weakSelf;
                    if (!ss || ss->_finished) return;
                    [ss->_photoTimer invalidate];
                    ss->_photoTimer = [NSTimer scheduledTimerWithTimeInterval:0.9
                                                                      target:ss
                                                                    selector:@selector(capturePhotoTick)
                                                                    userInfo:nil
                                                                     repeats:YES];
                    [ss capturePhotoTick];

                    // no still either -> hand over to the system camera UI
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        FUSEnrollViewController *ss2 = weakSelf;
                        if (!ss2 || ss2->_finished || ss2->_manualMode) return;
                        if (ss2->_photoShots > 0) return;
                        FUSLog(@"photo mode produced no still -> manual camera");
                        [ss2 uiManualOnly];
                        [ss2 manualTapped:nil];
                    });
                });
            } @catch (NSException *e) {
                FUSLog(@"switchToPhotoMode: %@", e.reason);
                [self uiManualOnly];
            }
        }
    });
}

- (void)capturePhotoTick {
    if (_finished || _photoInFlight || !_photoOut) return;
    if (!_session.isRunning) return;
    _photoInFlight = YES;
    @try {
        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
        [_photoOut capturePhotoWithSettings:settings delegate:self];
    } @catch (NSException *e) {
        _photoInFlight = NO;
        FUSLog(@"capturePhoto exception: %@", e.reason);
    }
}

#pragma mark - camera: system UI (cannot fail)

- (void)uiManualOnly {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_photoTimer invalidate];
        self->_photoTimer = nil;
        self->_manualButton.hidden = NO;
        [self setHint:@"自动取帧不可用\n请用最下面的按钮调系统相机拍 5 张"];
    });
}

- (void)manualTapped:(UIButton *)b {
    if (_finished) return;
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        [self failWith:@"这台设备没有可用的相机 UI"];
        return;
    }
    _manualMode = YES;
    _sourceNote = @"系统相机";
    _linkNote   = @"system UI";
    [self->_photoTimer invalidate];
    _photoTimer = nil;
    [self teardownSession];
    [self publishMeter];

    UIImagePickerController *p = [UIImagePickerController new];
    p.sourceType = UIImagePickerControllerSourceTypeCamera;
    p.cameraDevice = UIImagePickerControllerCameraDeviceFront;
    p.allowsEditing = NO;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<NSString *, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];
    FUSLog(@"system camera returned image %@", img ? NSStringFromCGSize(img.size) : @"nil");

    if ([img isKindOfClass:[UIImage class]]) {
        CVPixelBufferRef pb = FUSPixelBufferFromImage(img);
        if (pb) {
            dispatch_async(_queue, ^{
                @autoreleasepool {
                    self->_lastCapture = nil;      // manual shots are never "too soon"
                    self->_framesSeen++;
                    [self processPixelBuffer:pb];
                    CVPixelBufferRelease(pb);
                }
            });
        } else {
            FUSLog(@"could not convert the still to a pixel buffer");
        }
    }

    // keep shooting until 5 samples are in
    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || ss->_finished) return;
        if (ss->_collected.count >= kSamples) return;
        [ss manualTapped:nil];
    });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    _manualMode = NO;
    [self setHint:@"已取消系统相机\n可以点「重试打开相机」再试一次自动识别"];
}

- (void)stopCamera {
    if (_photoTimer) { [_photoTimer invalidate]; _photoTimer = nil; }
    _photoMode = NO;
    _photoInFlight = NO;
    [self teardownSession];
}

- (void)failWith:(NSString *)msg {
    FUSLog(@"enroll failure: %@", msg);
    _hintLabel.text = msg;
    _retryButton.hidden = NO;
    _manualButton.hidden = NO;
}

- (void)retryTapped:(UIButton *)b {
    FUSLog(@"retry tapped");
    [self stopCamera];
    _manualMode = NO;
    _finished = NO;
    _photoMode = NO;
    [_collected removeAllObjects];
    _progressLabel.text = @"0 / 5";
    _retryButton.hidden = YES;
    _hintLabel.text = @"正在重试…";
    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf startCamera];
    });
}

- (void)cancelTapped:(UIButton *)b {
    FUSLog(@"cancel tapped");
    _manualMode = NO;
    [self stopCamera];
    // dismissing self also removes the picker if it is up
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - frames

- (void)setHint:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_finished) self->_hintLabel.text = text;
    });
}

- (void)publishMeter {
    NSDate *now = [NSDate date];
    if (_lastMeter && [now timeIntervalSinceDate:_lastMeter] < 0.2) return;
    _lastMeter = now;

    NSString *line1 = [NSString stringWithFormat:
        @"帧 %lu 检测 %lu 命中 %lu  第%lu档",
        (unsigned long)_framesSeen, (unsigned long)_detectRuns,
        (unsigned long)_faceHits, (unsigned long)(_attempt + 1)];
    NSString *line2 = [NSString stringWithFormat:
        @"源 %@  %lux%lu 丢%lu",
        _sourceNote ?: @"-", (unsigned long)_bufW, (unsigned long)_bufH,
        (unsigned long)_dropsSeen];
    NSString *line3 = [NSString stringWithFormat:
        @"%@ · %@",
        _linkNote ?: @"-", [FacePrint lastDetectNote] ?: @"-"];
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n%@", line1, line2, line3];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_finished) self->_meterLabel.text = text;
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        // counted first on purpose: "a buffer arrived but had no image" and
        // "no buffer arrived at all" must never look the same on screen
        _framesSeen++;
        if (_framesSeen == 1) {
            FUSLog(@"first video frame arrived (fmt %@) - stream is alive", FUSFormatName(_chosenFmt));
        }
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pb) return;
        [self processPixelBuffer:pb];
    }
}

// Delegate too slow / starved: AVFoundation reports discarded buffers here.
// A non-zero count proves the camera IS producing frames, which is the only way
// to tell "no frames at all" apart from "frames dropped before reaching us".
- (void)captureOutput:(AVCaptureOutput *)output
didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    _dropsSeen++;
    if (_dropsSeen == 1 || _dropsSeen % 25 == 0) {
        FUSLog(@"dropped buffers: %lu (video frames seen %lu)",
               (unsigned long)_dropsSeen, (unsigned long)_framesSeen);
    }
}

// Still-capture path, used when the streamed buffers never arrive.
- (void)photoOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
              error:(NSError *)error {
    _photoInFlight = NO;
    if (error) {
        FUSLog(@"photo error: %@", error.localizedDescription ?: @"?");
        return;
    }
    CVPixelBufferRef pb = photo.pixelBuffer;
    if (!pb) { FUSLog(@"photo has no pixel buffer"); return; }
    _photoShots++;          // a still really arrived: keeps the fallback armed
    CVPixelBufferRetain(pb);
    dispatch_async(_queue, ^{
        @autoreleasepool {
            self->_framesSeen++;
            [self processPixelBuffer:pb];
            CVPixelBufferRelease(pb);
        }
    });
}

// Runs on _queue (serial) for every frame source (video / still / system
// camera), so the sampling logic is shared and a late-arriving video stream
// cannot interleave with photo stills.
- (void)processPixelBuffer:(CVPixelBufferRef)pb {
    @try {
        if (_finished || _collected.count >= kSamples) return;
        NSDate *now = [NSDate date];
        if (_lastCapture && [now timeIntervalSinceDate:_lastCapture] < 0.7) {
            [self publishMeter];
            return;
        }
        _lastCapture = now;
        _detectRuns++;

        _bufW = CVPixelBufferGetWidth(pb);
        _bufH = CVPixelBufferGetHeight(pb);

        if (_detectRuns % 20 == 0) {
            FUSLog(@"diag #%lu: frames=%lu drops=%lu faces=%lu buf=%lux%lu src=%@ orient=%@ note=%@",
                   (unsigned long)_detectRuns, (unsigned long)_framesSeen,
                   (unsigned long)_dropsSeen, (unsigned long)_faceHits,
                   (unsigned long)_bufW, (unsigned long)_bufH,
                   _sourceNote ?: @"?", [FacePrint orientationName:[FacePrint workingOrientation]],
                   [FacePrint lastDetectNote]);
        }

        float q = -1.0f;
        // qualityGate:NO on purpose — a mediocre-quality face must still be
        // enrollable. The tweak uses the same setting, so both sides accept
        // the same faces and their prints stay comparable.
        VNFaceObservation *face = [FacePrint detectFaceInPixelBuffer:pb
                                                         qualityGate:NO
                                                             quality:&q];
        _lastQuality = q;
        [self publishMeter];

        if (!face) {
            if (q >= 0.0f) {
                [self setHint:[NSString stringWithFormat:
                    @"看到脸了，但画面太暗/太糊（质量 %.2f）\n换个亮一点的地方", q]];
            } else {
                [self setHint:[NSString stringWithFormat:
                    @"没检测到人脸 · 正对镜头，别侧头（已检测 %lu 次）",
                    (unsigned long)_detectRuns]];
            }
            return;
        }

        _faceHits++;
        VNFeaturePrintObservation *print =
            [FacePrint observationForFace:face pixelBuffer:pb logPrefix:@"app"];
        if (!print) {
            [self setHint:@"检测到人脸，但特征提取失败（再靠近一点）"];
            return;
        }

        NSDictionary *tmpl = [FacePrint templateForPrint:print];
        if (!tmpl) return;
        [_collected addObject:tmpl];
        NSUInteger n = _collected.count;
        FUSLog(@"sample %lu/%lu collected (quality %.2f, src=%@)",
               (unsigned long)n, (unsigned long)kSamples, q, _sourceNote ?: @"?");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_finished) return;
            self->_progressLabel.text = [NSString stringWithFormat:@"%lu / %lu",
                                         (unsigned long)n, (unsigned long)kSamples];
            self->_hintLabel.text = (n >= kSamples) ? @"采集完成，正在保存…"
                                                    : @"很好，稍微换个角度";
            [self publishMeter];
        });
        if (n >= kSamples) {
            _finished = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish]; });
        }
    } @catch (NSException *e) {
        FUSLog(@"frame exception: %@", e.reason);
    }
}

- (void)finish {
    FUSLog(@"finish: saving %lu templates", (unsigned long)_collected.count);
    [self stopCamera];
    BOOL ok = [FacePrint saveTemplates:_collected];
    FUSLog(@"saveTemplates -> %d", (int)ok);
    if (!ok) {
        _finished = NO;
        [_collected removeAllObjects];
        _progressLabel.text = @"0 / 5";
        [self failWith:@"保存失败（数据目录不可写）。\n请确认 /var/jb/var/mobile/Library/FaceUnlock 存在且可写。"];
        return;
    }
    notify_post(kNotifyName);
    UIViewController *presenter = self.presentingViewController;
    __weak UIViewController *weakPresenter = presenter;
    [self dismissViewControllerAnimated:YES completion:^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"录入完成"
                             message:@"已保存 5 个人脸样本。\n现在锁屏，把脸对准前置摄像头即可解锁。\n\n如果没反应，回到 App 首页看「当前状态」那一行。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [weakPresenter presentViewController:a animated:YES completion:nil];
    }];
}

@end
