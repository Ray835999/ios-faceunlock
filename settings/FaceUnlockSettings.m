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
#import <PhotosUI/PhotosUI.h>
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

    _versionLabel = [self label:@"v2.6.0 · 相册导入版" size:12 weight:UIFontWeightRegular
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
// ---------------------------------------------------------------------------
// v2.3.0 — ONE session, TWO frame sources, ZERO session churn.
//
// Why this was rewritten instead of patched a fourth time:
//
//   * The 2.2.0 "format ladder" built four sessions in a row.  Every rebuild
//     detached the preview, stopped the old session and started a new one —
//     that is the black flash on screen ("闪一下，好像是崩了").  It also leaves
//     the camera half-released, so the next startRunning() has no guarantee of
//     succeeding.
//   * Every rung *forced* a pixel format through videoSettings.  Forcing a
//     format on AVCaptureVideoDataOutput is what muted the connection on this
//     device: the preview kept rendering (it owns a separate connection) while
//     the data output delivered nothing.  The video output now gets **no
//     videoSettings at all** and lets AVFoundation negotiate.  FacePrint works
//     through CIImage / Vision and does not care which format arrives.
//   * When no video frame comes, stills are pulled from the SAME session via
//     AVCapturePhotoOutput: no teardown, no second session, no flash, and no
//     two clients fighting over the camera device.
//   * The system camera UI is presented only after the capture session has
//     really stopped.  In 2.2.0 the picker was presented while stopRunning()
//     was still in flight, so Apple's own camera could not grab the device and
//     pressing the shutter did nothing at all.
//
// All sources feed the single processPixelBuffer: below, so the saved
// templates stay comparable with what the lock-screen tweak computes.
// ---------------------------------------------------------------------------

#pragma mark - enrollment

static const NSUInteger kSamples = 5;

// UIImage (system camera / still) -> BGRA CVPixelBuffer, uniformly scaled so
// the face geometry stays comparable with the live frames.  A plain bitmap
// context is used on purpose: no CIContext, no GPU context to fail to create.
static CVPixelBufferRef FUSPixelBufferFromImage(UIImage *img) {
    if (![img isKindOfClass:[UIImage class]]) return NULL;
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return NULL;

    double scale = 960.0 / (double)MAX(w, h);
    if (scale > 1.0) scale = 1.0;
    size_t dw = (size_t)llround((double)w * scale);
    size_t dh = (size_t)llround((double)h * scale);
    if (dw < 2 || dh < 2) return NULL;

    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, dw, dh,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    if (!pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    void  *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr  = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, dw, dh, 8, bpr, cs,
                                             kCGImageAlphaPremultipliedFirst |
                                             kCGBitmapByteOrder32Little);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CVPixelBufferRelease(pb);
        return NULL;
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)dw, (CGFloat)dh), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// UIImage -> template, with a user-facing reason when it cannot be used.
// Shared by the album import and the in-app shutter so both routes feed the
// same detect / feature-print / template pipeline and stay comparable.
static NSDictionary *FUSTemplateFromImage(UIImage *img, NSString **why) {
    if (why) *why = nil;
    if (![img isKindOfClass:[UIImage class]] || !img.CGImage) {
        if (why) *why = @"这张不是能读的图片";
        return nil;
    }
    CVPixelBufferRef pb = FUSPixelBufferFromImage(img);
    if (!pb) {
        if (why) *why = @"图片转换失败（尺寸异常？）";
        return nil;
    }
    float q = -1.0f;
    VNFaceObservation *face = [FacePrint detectFaceInPixelBuffer:pb
                                                     qualityGate:NO
                                                         quality:&q];
    if (!face) {
        if (why) *why = (q >= 0.0f)
            ? [NSString stringWithFormat:@"太暗/太糊（质量 %.2f）", q]
            : @"这张里没检测到人脸";
        CVPixelBufferRelease(pb);
        return nil;
    }
    VNFeaturePrintObservation *pr = [FacePrint observationForFace:face
                                                      pixelBuffer:pb
                                                        logPrefix:@"album"];
    CVPixelBufferRelease(pb);
    if (!pr) {
        if (why) *why = @"特征提取失败";
        return nil;
    }
    NSDictionary *t = [FacePrint templateForPrint:pr];
    if (!t && why) *why = @"特征生成失败";
    return t;
}

@interface FUSEnrollViewController () <UIImagePickerControllerDelegate,
                                       UINavigationControllerDelegate,
                                       PHPickerViewControllerDelegate>
@end

#pragma mark - in-app shutter
//
// Why this class exists: UIImagePickerController with sourceType == Camera is
// unusable on this device.  One shot works, then its own UI stops responding —
// only the system "Cancel" button stays alive, so enrollment can never finish.
//
// Here every control is a UIButton we own, and the session carries nothing but
// a camera input and an AVCapturePhotoOutput.  There is no video-data output at
// all — that is the path that never delivered a single frame — so the still
// path (ISP) is completely independent of it.

@interface FUSShotViewController : UIViewController <AVCapturePhotoCaptureDelegate> {
    AVCaptureSession           *_sSession;
    AVCapturePhotoOutput       *_sPhotoOut;
    AVCaptureVideoPreviewLayer *_sPreview;
    dispatch_queue_t            _sSessQ;
    dispatch_queue_t            _sWorkQ;
    UIButton                   *_sShutter;
    UIButton                   *_sDone;
    UIButton                   *_sCancel;
    UILabel                    *_sProgress;
    UILabel                    *_sHint;
    BOOL                        _sBusy;
    BOOL                        _sFinished;
    BOOL                        _sBuilding;
    NSUInteger                  _sShots;
    NSUInteger                  _sFails;
    NSUInteger                  _sShotGen;
    NSMutableArray             *_sTemplates;
}

// nil payload means "closed without new samples" (user cancelled)
@property (nonatomic, copy) void (^onClose)(NSArray *tpls);

@end

@implementation FUSShotViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    FUSLog(@"shot viewDidLoad");
    self.view.backgroundColor = [UIColor blackColor];
    _sTemplates = [NSMutableArray array];
    _sSessQ = dispatch_queue_create("com.ray835999.faceunlock.shot.session",
                                    DISPATCH_QUEUE_SERIAL);
    _sWorkQ = dispatch_queue_create("com.ray835999.faceunlock.shot.work",
                                    DISPATCH_QUEUE_SERIAL);

    _sPreview = [AVCaptureVideoPreviewLayer new];
    _sPreview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _sPreview.frame = self.view.bounds;
    [self.view.layer addSublayer:_sPreview];

    _sProgress = [self label:@"0 / 5" size:17 weight:UIFontWeightSemibold];
    _sProgress.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_sProgress];

    _sHint = [self label:@"把脸放进画面中间，然后按下面的白色圆钮" size:14
                  weight:UIFontWeightRegular];
    _sHint.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _sHint.numberOfLines = 0;
    _sHint.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_sHint];

    _sShutter = [UIButton buttonWithType:UIButtonTypeCustom];
    _sShutter.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _sShutter.layer.cornerRadius = 38;
    _sShutter.layer.borderWidth = 3;
    _sShutter.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    _sShutter.exclusiveTouch = YES;
    [_sShutter addTarget:self action:@selector(shutterTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_sShutter];

    _sDone = [UIButton buttonWithType:UIButtonTypeSystem];
    [_sDone setTitle:@"完成" forState:UIControlStateNormal];
    [_sDone setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _sDone.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _sDone.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.85 alpha:1];
    _sDone.layer.cornerRadius = 8;
    _sDone.exclusiveTouch = YES;
    _sDone.hidden = YES;
    [_sDone addTarget:self action:@selector(doneTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_sDone];

    _sCancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [_sCancel setTitle:@"取消" forState:UIControlStateNormal];
    [_sCancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _sCancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _sCancel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    _sCancel.layer.cornerRadius = 8;
    _sCancel.exclusiveTouch = YES;
    [_sCancel addTarget:self action:@selector(cancelTapped:)
       forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_sCancel];

    [self buildSession];
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

    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    _sPreview.frame = self.view.bounds;

    _sCancel.frame    = CGRectMake(insets.left + 14, insets.top + 8, 68, 38);
    _sProgress.frame  = CGRectMake(90, insets.top + 12, w - 180, 30);

    CGFloat shutterY = h - insets.bottom - 96;
    _sShutter.frame = CGRectMake((w - 76) / 2, shutterY, 76, 76);

    _sHint.frame = CGRectMake(20, shutterY - 56, w - 40, 44);
    _sDone.frame = CGRectMake(w - insets.right - 14 - 104, shutterY + 16, 104, 44);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_sFinished) return;
    [self startSession];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (_sFinished) return;
    [self stopSessionThen:nil];
}

#pragma mark session

- (void)buildSession {
    if (_sSession || _sBuilding) return;
    _sBuilding = YES;
    __weak FUSShotViewController *weakSelf = self;
    dispatch_async(_sSessQ, ^{
        @autoreleasepool {
            FUSShotViewController *ss = weakSelf;
            if (!ss) return;
            @try {
                AVCaptureSession *s = [AVCaptureSession new];
                s.sessionPreset = AVCaptureSessionPreset640x480;

                AVCaptureDevice *dev = nil;
                AVCaptureDeviceDiscoverySession *ds =
                    [AVCaptureDeviceDiscoverySession
                        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                              mediaType:AVMediaTypeVideo
                                               position:AVCaptureDevicePositionFront];
                dev = ds.devices.firstObject;
                if (!dev) dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
                if (!dev) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [ss say:@"这台设备没有可用的摄像头"];
                    });
                    return;
                }
                FUSLog(@"shot using device %@ (front=%d)", dev.localizedName,
                       (int)(dev.position == AVCaptureDevicePositionFront));

                NSError *err = nil;
                AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev
                                                                                error:&err];
                if (!in || ![s canAddInput:in]) {
                    FUSLog(@"shot cannot add input: %@", err);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [ss say:@"无法打开摄像头\n点右上角取消，改用相册录入"];
                    });
                    return;
                }
                [s addInput:in];

                // stills only — no video-data output, that is the mute path
                AVCapturePhotoOutput *po = [AVCapturePhotoOutput new];
                if (![s canAddOutput:po]) {
                    FUSLog(@"shot cannot add photo output");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [ss say:@"这台设备不支持拍照输出\n点右上角取消，改用相册录入"];
                    });
                    return;
                }
                [s addOutput:po];

                ss->_sSession  = s;
                ss->_sPhotoOut = po;
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sBuilding = NO;
                    ss->_sPreview.session = s;
                    FUSLog(@"shot session ready, starting");
                    [ss startSession];
                });
            } @catch (NSException *e) {
                FUSLog(@"shot build exception: %@", e.reason);
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sBuilding = NO;
                    [ss say:[NSString stringWithFormat:@"相机初始化异常：%@", e.reason ?: @"?"]];
                });
            }
        }
    });
}

- (void)startSession {
    AVCaptureSession *s = _sSession;
    if (!s) return;
    if (s.isRunning) { [self say:@"对准脸，按白色圆钮"]; return; }
    __weak FUSShotViewController *weakSelf = self;
    dispatch_async(_sSessQ, ^{
        @autoreleasepool {
            @try { [s startRunning]; } @catch (NSException *e) {
                FUSLog(@"shot startRunning exception: %@", e.reason);
            }
            BOOL running = s.isRunning;
            FUSLog(@"shot session running=%d", (int)running);
            dispatch_async(dispatch_get_main_queue(), ^{
                FUSShotViewController *ss = weakSelf;
                if (!ss) return;
                if (!running) { [ss say:@"相机没起来\n点右上角取消，改用相册录入"]; return; }
                [ss say:@"对准脸，按白色圆钮"];
            });
        }
    });
}

- (void)stopSessionThen:(void (^)(void))done {
    AVCaptureSession *s = _sSession;
    _sSession = nil;
    _sPhotoOut = nil;
    void (^after)(void) = ^{ if (done) done(); };
    if (!s) { after(); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_sPreview.session == s) self->_sPreview.session = nil;
        dispatch_async(self->_sSessQ, ^{
            @autoreleasepool { @try { [s stopRunning]; } @catch (NSException *e) {} }
            dispatch_async(dispatch_get_main_queue(), after);
        });
    });
}

#pragma mark shutter

- (void)shutterTapped:(UIButton *)b {
    if (_sFinished || _sBusy) return;
    if (!_sPhotoOut || !_sSession.isRunning) {
        [self say:@"相机还没准备好，等一下再按"];
        [self startSession];
        return;
    }
    _sBusy = YES;
    _sShots++;
    NSUInteger gen = ++_sShotGen;
    [self say:@"正在拍照…"];

    __weak FUSShotViewController *weakSelf = self;
    dispatch_async(_sSessQ, ^{
        @autoreleasepool {
            FUSShotViewController *ss = weakSelf;
            if (!ss) return;
            @try {
                AVCapturePhotoSettings *st = [AVCapturePhotoSettings photoSettings];
                // the front camera has no flash; setting it would throw
                NSArray *modes = ss->_sPhotoOut.supportedFlashModes;
                if ([modes isKindOfClass:[NSArray class]] &&
                    [modes containsObject:@(AVCaptureFlashModeOff)]) {
                    st.flashMode = AVCaptureFlashModeOff;
                }
                [ss->_sPhotoOut capturePhotoWithSettings:st delegate:ss];
            } @catch (NSException *e) {
                FUSLog(@"shot capture exception: %@", e.reason);
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sBusy = NO;
                    ss->_sFails++;
                    [ss say:[NSString stringWithFormat:@"快门失败：%@", e.reason ?: @"?"]];
                    [ss updateMeter];
                });
            }
        }
    });

    // a still that never reports back must not lock the shutter forever
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUSShotViewController *ss = weakSelf;
        if (!ss || ss->_sFinished) return;
        if (ss->_sShotGen != gen || !ss->_sBusy) return;
        FUSLog(@"shot watchdog: no callback in 5s");
        ss->_sBusy = NO;
        ss->_sFails++;
        [ss say:@"这张没有回应\n再按一次，或点右上角取消用相册"];
        [ss updateMeter];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
               error:(NSError *)error {
    _sBusy = NO;
    if (error || !photo) {
        FUSLog(@"shot delegate error: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_sFails++;
            [self say:@"这张没拍成\n再按一次快门"];
            [self updateMeter];
        });
        return;
    }

    NSData *d = nil;
    UIImage *img = nil;
    @try { d = [photo fileDataRepresentation]; } @catch (NSException *e) {}
    if (d.length) img = [UIImage imageWithData:d];
    if (!img) {
        FUSLog(@"shot has no usable image (data=%lu)", (unsigned long)d.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_sFails++;
            [self say:@"这张照片取不出来\n再按一次快门"];
            [self updateMeter];
        });
        return;
    }
    [self processStill:img];
}

- (void)processStill:(UIImage *)img {
    [self say:@"识别中…"];
    __weak FUSShotViewController *weakSelf = self;
    dispatch_async(_sWorkQ, ^{
        @autoreleasepool {
            FUSShotViewController *ss = weakSelf;
            if (!ss) return;
            CVPixelBufferRef pb = FUSPixelBufferFromImage(img);
            if (!pb) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sFails++;
                    [ss say:@"照片转换失败\n再按一次快门（正对镜头、光线亮一点）"];
                    [ss updateMeter];
                });
                return;
            }
            float q = -1.0f;
            VNFaceObservation *face = [FacePrint detectFaceInPixelBuffer:pb
                                                             qualityGate:NO
                                                                 quality:&q];
            if (!face) {
                CVPixelBufferRelease(pb);
                NSString *why = (q >= 0.0f)
                    ? [NSString stringWithFormat:@"太暗/太糊（质量 %.2f）\n换个亮一点、近一点", q]
                    : @"没检测到人脸\n正对镜头，别侧头、别低头";
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sFails++;
                    [ss say:why];
                    [ss updateMeter];
                });
                return;
            }
            VNFeaturePrintObservation *pr = [FacePrint observationForFace:face
                                                              pixelBuffer:pb
                                                                logPrefix:@"shot"];
            CVPixelBufferRelease(pb);
            if (!pr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sFails++;
                    [ss say:@"特征提取失败\n再靠近一点"];
                    [ss updateMeter];
                });
                return;
            }
            NSDictionary *t = [FacePrint templateForPrint:pr];
            if (!t) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ss->_sFails++;
                    [ss say:@"特征生成失败\n再按一次快门"];
                    [ss updateMeter];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ss->_sFinished) return;
                [ss->_sTemplates addObject:t];
                FUSLog(@"shot sample %lu/%lu collected",
                       (unsigned long)ss->_sTemplates.count, (unsigned long)kSamples);
                [ss updateMeter];
                if (ss->_sTemplates.count >= kSamples) {
                    [ss finishWithTemplates];
                } else {
                    [ss say:@"很好 · 稍微换个角度再按一次"];
                }
            });
        }
    });
}

- (void)doneTapped:(UIButton *)b {
    [self finishWithTemplates];
}

- (void)finishWithTemplates {
    if (_sFinished) return;
    _sFinished = YES;
    NSArray *out = [_sTemplates copy];
    FUSLog(@"shot finishing with %lu sample(s)", (unsigned long)out.count);
    __weak FUSShotViewController *weakSelf = self;
    [self stopSessionThen:^{
        FUSShotViewController *ss = weakSelf;
        if (!ss) return;
        void (^cb)(NSArray *) = ss.onClose;
        [ss dismissViewControllerAnimated:YES completion:^{
            if (cb) cb(out);
        }];
    }];
}

- (void)cancelTapped:(UIButton *)b {
    if (_sFinished) return;
    _sFinished = YES;
    FUSLog(@"shot cancelled (%lu good)", (unsigned long)_sTemplates.count);
    __weak FUSShotViewController *weakSelf = self;
    [self stopSessionThen:^{
        FUSShotViewController *ss = weakSelf;
        if (!ss) return;
        void (^cb)(NSArray *) = ss.onClose;
        [ss dismissViewControllerAnimated:YES completion:^{
            if (cb) cb(nil);
        }];
    }];
}

#pragma mark ui

- (void)say:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_sFinished) return;
        self->_sHint.text = text;
    });
}

- (void)updateMeter {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_sFinished) return;
        self->_sProgress.text = [NSString stringWithFormat:@"%lu / %lu",
                                 (unsigned long)self->_sTemplates.count,
                                 (unsigned long)kSamples];
        if (self->_sTemplates.count > 0) {
            self->_sDone.hidden = NO;
            [self->_sDone setTitle:[NSString stringWithFormat:@"完成（%lu 张）",
                                    (unsigned long)self->_sTemplates.count]
                          forState:UIControlStateNormal];
        }
    });
}

@end


@implementation FUSEnrollViewController {
    AVCaptureSession         *_session;
    AVCaptureVideoDataOutput *_output;
    AVCapturePhotoOutput     *_photoOut;

    // Two queues on purpose: session configuration/start/stop and the sample
    // buffer callbacks must never share a queue.  startRunning() blocks, and
    // when it runs on the delegate queue the first frames are starved for as
    // long as it takes.
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
    NSUInteger                _framesAtStart;
    NSUInteger                _detectRuns;
    NSUInteger                _faceHits;
    NSUInteger                _bufW;
    NSUInteger                _bufH;
    NSUInteger                _dropsSeen;
    NSUInteger                _photoShots;    // stills that really arrived
    NSUInteger                _photoFails;    // still captures that died
    NSString                 *_sourceNote;    // 视频 / 照片 / 系统相机
    NSString                 *_linkNote;      // session/connection state
    float                     _lastQuality;

    BOOL                      _finished;
    BOOL                      _cameraConfigured;
    BOOL                      _building;
    BOOL                      _permissionResolved;
    BOOL                      _photoMode;     // still pump running
    BOOL                      _photoInFlight;
    BOOL                      _manualMode;    // system camera UI in use
    BOOL                      _pickerUp;
    NSUInteger                _presentRetries;

    // album import: the only route that never touches the capture device
    UIButton                 *_camButton;
    BOOL                      _albumRunning;
    NSUInteger                _albumPicked;
    NSUInteger                _albumDone;
    NSUInteger                _albumBad;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    FUSLog(@"enroll viewDidLoad (v2.6.0 album import)");
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

    // Three lines of monospaced text.  A screenshot of this block is the whole
    // diagnosis:
    //   line 1  counters + where the frames come from
    //   line 2  buffer size, dropped buffers, still-shutter counters
    //   line 3  session state + where detection stopped
    _meterLabel = [self label:@"帧 0 检测 0 命中 0" size:10 weight:UIFontWeightRegular];
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

    // Primary route: import from the album.  PHPicker runs out of process and
    // never opens the capture device, so it cannot be starved the way an
    // in-process AVCaptureSession can — this is the route that always works.
    _manualButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_manualButton setTitle:@"① 从相册选照片（推荐）" forState:UIControlStateNormal];
    [_manualButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _manualButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _manualButton.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.85 alpha:1];
    _manualButton.layer.cornerRadius = 8;
    _manualButton.exclusiveTouch = YES;
    [_manualButton addTarget:self action:@selector(albumTapped:)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_manualButton];

    // Secondary route: our own camera page, top-right.  Kept because it is the
    // only path that produces a fresh sample on devices where captures work.
    _camButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_camButton setTitle:@"② 相机" forState:UIControlStateNormal];
    [_camButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _camButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _camButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _camButton.layer.cornerRadius = 9;
    _camButton.exclusiveTouch = YES;
    [_camButton addTarget:self action:@selector(manualTapped:)
         forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_camButton];

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
    // the meter, so the block never collides with the guide circle
    CGFloat rowH = 44;
    CGFloat rowY = meterY - 8 - rowH;

    _cancelButton.frame  = CGRectMake(insets.left + 16, insets.top + 8, 68, 38);
    _camButton.frame     = CGRectMake(w - insets.right - 16 - 72, insets.top + 8, 72, 38);
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
    FUSLog(@"enroll viewDidAppear (manual=%d picker=%d)", (int)_manualMode, (int)_pickerUp);
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
    if (_cameraConfigured || _building || _manualMode) return;

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
                if (granted) [ss beginCapture];
                else [ss failWith:@"需要相机权限才能录入人脸。\n请到 设置 → 隐私 → 相机 里允许 FaceUnlock。"];
            });
        }];
        return;
    }
    [self beginCapture];
}

#pragma mark - camera: the one session

- (void)beginCapture {
    if (_finished || _manualMode || _cameraConfigured || _building) return;
    _building   = YES;
    _sourceNote = @"视频 自动格式";
    _linkNote   = @"building";
    [self setHint:@"正在打开相机…"];
    [self publishMeter];

    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        [weakSelf buildCaptureSession];
    });
}

// runs on _sessionQueue
- (void)buildCaptureSession {
    @autoreleasepool {
        @try {
            AVCaptureDeviceDiscoverySession *disc =
                [AVCaptureDeviceDiscoverySession
                    discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                          mediaType:AVMediaTypeVideo
                                           position:AVCaptureDevicePositionFront];
            AVCaptureDevice *cam = disc.devices.firstObject;
            if (!cam) { _building = NO; [self uiFail:@"没有找到前置摄像头"]; return; }

            NSError *err = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
            if (!input) {
                _building = NO;
                [self uiFail:[NSString stringWithFormat:@"打开摄像头失败：%@",
                              err.localizedDescription ?: @"未知错误"]];
                return;
            }

            AVCaptureSession *session = [AVCaptureSession new];
            AVCaptureVideoDataOutput *video = [AVCaptureVideoDataOutput new];
            video.alwaysDiscardsLateVideoFrames = YES;
            // NO videoSettings on purpose — see the header comment.  Letting
            // AVFoundation negotiate is the whole point of this rewrite.

            AVCapturePhotoOutput *photo = [AVCapturePhotoOutput new];
            @try {
                if ([photo respondsToSelector:NSSelectorFromString(@"setHighResolutionCaptureEnabled:")]) {
                    [photo setValue:@NO forKey:@"highResolutionCaptureEnabled"];
                }
            } @catch (NSException *e) {}

            [session beginConfiguration];
            NSString *preset = AVCaptureSessionPreset640x480;
            if ([session canSetSessionPreset:preset]) session.sessionPreset = preset;
            if (![session canAddInput:input]) {
                [session commitConfiguration];
                _building = NO;
                [self uiFail:@"无法添加相机输入"];
                return;
            }
            [session addInput:input];
            if (![session canAddOutput:video]) {
                [session commitConfiguration];
                _building = NO;
                [self uiFail:@"无法添加视频输出"];
                return;
            }
            [session addOutput:video];
            BOOL photoAdded = NO;
            if ([session canAddOutput:photo]) {
                [session addOutput:photo];
                photoAdded = YES;
            }
            [session commitConfiguration];

            [video setSampleBufferDelegate:self queue:_queue];

            AVCaptureConnection *conn = [video connectionWithMediaType:AVMediaTypeVideo];
            if (conn) {
                conn.enabled = YES;
                if (conn.supportsVideoOrientation) {
                    conn.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
            }

            _session  = session;
            _output   = video;
            _photoOut = photoAdded ? photo : nil;
            _linkNote = [NSString stringWithFormat:@"out%lu vid%@ photo%@",
                         (unsigned long)session.outputs.count,
                         conn ? @"1" : @"0", photoAdded ? @"1" : @"0"];
            FUSLog(@"capture session built: %@ preset=%@", _linkNote, session.sessionPreset);

            dispatch_async(dispatch_get_main_queue(), ^{
                self->_preview.session = session;
                self->_cameraConfigured = YES;
                self->_building = NO;
                self->_retryButton.hidden = YES;
                self->_hintLabel.text = @"把脸放进圆圈里，保持不动";
                [self publishMeter];
            });

            // already on the session queue: startRunning may block here freely
            @try { [session startRunning]; }
            @catch (NSException *e) { FUSLog(@"startRunning: %@", e.reason); }

            AVCaptureConnection *c2 = [video connectionWithMediaType:AVMediaTypeVideo];
            _linkNote = [NSString stringWithFormat:@"run%@ act%@ en%@ photo%@",
                         session.isRunning ? @"1" : @"0",
                         (c2 && c2.isActive) ? @"1" : @"0",
                         (c2 && c2.enabled)  ? @"1" : @"0",
                         photoAdded ? @"1" : @"0"];
            FUSLog(@"startRunning done: %@", _linkNote);

            NSUInteger framesAtStart = _framesSeen;
            __weak FUSEnrollViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FUSEnrollViewController *ss = weakSelf;
                if (!ss || ss->_finished || ss->_manualMode) return;
                if (ss->_framesSeen > framesAtStart) return;   // video works, done
                FUSLog(@"no video frame in 1.5s -> still pump on the SAME session");
                [ss startPhotoPump];

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    FUSEnrollViewController *s2 = weakSelf;
                    if (!s2 || s2->_finished || s2->_manualMode) return;
                    if (s2->_framesSeen > framesAtStart) return;
                    FUSLog(@"still pump produced nothing either -> system camera");
                    [s2 uiManualOnly];
                });
            });
        } @catch (NSException *e) {
            _building = NO;
            FUSLog(@"buildCaptureSession exception: %@", e.reason);
            [self uiFail:[NSString stringWithFormat:@"相机初始化异常：%@", e.reason ?: @"?"]];
        }
    }
}

- (void)uiFail:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{ [self failWith:msg]; });
}

// Stop the session, and only then run `done`.  Used before the system camera
// UI opens: the picker needs the device, and it must not be handed a camera
// that is still being released.
- (void)teardownSessionThen:(void (^)(void))done {
    AVCaptureSession *s = _session;
    _session = nil;
    _output  = nil;
    _photoOut = nil;
    _cameraConfigured = NO;
    _photoInFlight = NO;
    _photoMode = NO;
    _building = NO;

    void (^after)(void) = ^{ if (done) done(); };
    if (!s) { after(); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_preview.session == s) self->_preview.session = nil;
        dispatch_async(self->_sessionQueue, ^{
            @autoreleasepool {
                @try { [s stopRunning]; } @catch (NSException *e) {}
            }
            dispatch_async(dispatch_get_main_queue(), after);
        });
    });
}

#pragma mark - camera: stills from the same session

- (void)startPhotoPump {
    if (_photoTimer || _finished || _manualMode) return;
    if (!_photoOut) { [self uiManualOnly]; return; }
    _photoMode  = YES;
    _photoFails = 0;
    _sourceNote = @"照片";
    [self setHint:@"视频流没出帧，改用同一路相机连拍识别…"];
    [self publishMeter];

    _photoTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(pumpTick)
                                                userInfo:nil
                                                 repeats:YES];
    _photoTimer.tolerance = 0.2;
    [self pumpTick];
}

- (void)stopPhotoPump {
    void (^b)(void) = ^{
        [self->_photoTimer invalidate];
        self->_photoTimer  = nil;
        self->_photoMode   = NO;
        self->_photoInFlight = NO;
    };
    if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
}

// main thread
- (void)pumpTick {
    if (_finished || _manualMode) { [self stopPhotoPump]; return; }
    if (_photoInFlight) return;
    if (!_session || !_session.isRunning) return;
    [self takeStill];
}

- (void)takeStill {
    if (!_photoOut || _photoInFlight) return;
    @try {
        AVCapturePhotoSettings *st = [AVCapturePhotoSettings photoSettings];
        @try {
            // 1 == Speed; KVC keeps this safe on SDKs without the property
            [st setValue:@1 forKey:@"photoQualityPrioritization"];
        } @catch (NSException *e) {}
        _photoInFlight = YES;
        [_photoOut capturePhotoWithSettings:st delegate:self];

        __weak FUSEnrollViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FUSEnrollViewController *ss = weakSelf;
            if (!ss || !ss->_photoInFlight) return;
            ss->_photoInFlight = NO;      // the shutter never called back
            ss->_photoFails++;
            FUSLog(@"still %lu never called back (fails %lu)",
                   (unsigned long)ss->_photoShots, (unsigned long)ss->_photoFails);
            [ss publishMeter];
            if (ss->_photoFails >= 3) [ss uiManualOnly];
        });
    } @catch (NSException *e) {
        _photoInFlight = NO;
        _photoFails++;
        FUSLog(@"capturePhoto exception: %@", e.reason);
    }
}

#pragma mark - album import (out of process, never touches the capture device)
//
// On this device every in-process capture path is mute: the video-data output
// never delivers a buffer and AVCapturePhotoOutput never calls back, while the
// preview layer keeps rendering (it is drawn by mediaserverd, not by us).  The
// system camera app is broken in the same way.  PHPicker runs in its own
// process and only hands over decoded images, so it is the one route that can
// always produce a sample.

- (void)albumTapped:(UIButton *)b {
    if (_finished || _albumRunning || _pickerUp) return;
    FUSLog(@"albumTapped (collected %lu)", (unsigned long)_collected.count);
    _albumRunning = YES;          // lock for the whole album round-trip
    _manualMode = YES;
    _manualButton.hidden = NO;
    _sourceNote = @"相册";
    _linkNote   = @"phpicker";
    [self publishMeter];

    NSUInteger room = (_collected.count < kSamples) ? (kSamples - _collected.count) : 1;
    __weak FUSEnrollViewController *weakSelf = self;
    [self teardownSessionThen:^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || ss->_finished) return;
        if (ss.presentedViewController) {
            FUSLog(@"album blocked by %@", ss.presentedViewController);
            ss->_albumRunning = NO;
            [ss setHint:@"页面还盖着别的窗口\n等一下再点"];
            [ss refreshManualUI];
            return;
        }
        if (@available(iOS 14.0, *)) {
            [ss presentPHPickerWithRoom:room];
        } else {
            [ss openPicker:UIImagePickerControllerSourceTypePhotoLibrary];
        }
    }];
}

- (void)presentPHPickerWithRoom:(NSUInteger)room {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = (NSInteger)room;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    _pickerUp = YES;
    [self setHint:[NSString stringWithFormat:
        @"选 %lu 张正面自拍（已经没有脸的照片也没关系，一张也行）",
        (unsigned long)room]];
    FUSLog(@"presenting PHPicker, limit=%lu", (unsigned long)room);
    [self presentViewController:p animated:YES completion:^{
        FUSLog(@"PHPicker is up");
    }];

    // never leave the user on a screen where the tap "did nothing"
    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || ss->_finished || !ss->_pickerUp) return;
        if (ss.presentedViewController == p) return;
        FUSLog(@"PHPicker never came up");
        ss->_pickerUp = NO;
        ss->_albumRunning = NO;
        [ss setHint:@"相册界面没能打开\n再点一次，或用右上角「相机」"];
        [ss refreshManualUI];
    });
}

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    _pickerUp = NO;
    FUSLog(@"PHPicker returned %lu item(s)", (unsigned long)results.count);
    [picker dismissViewControllerAnimated:YES completion:nil];
    [self ingestPickerResults:results];
}

- (void)ingestPickerResults:(NSArray<PHPickerResult *> *)results {
    if (_finished) return;
    NSUInteger n = results.count;
    if (n == 0) {
        _albumRunning = NO;
        _pickerUp = NO;
        [self setHint:@"没有选中照片\n点左边按钮再来一次"];
        [self refreshManualUI];
        return;
    }
    _albumPicked  = n;
    __weak FUSEnrollViewController *weakSelf = self;
    __block NSUInteger pending = n;
    __block NSMutableArray *made = [NSMutableArray array];
    __block NSString *lastWhy = nil;
    [self setHint:[NSString stringWithFormat:@"正在识别 %lu 张照片…", (unsigned long)n]];

    // every item reports exactly once; the counter lives on the main queue so
    // no lock is needed
    void (^step)(NSDictionary *, NSString *) = ^(NSDictionary *t, NSString *why) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FUSEnrollViewController *ss = weakSelf;
            if (!ss) return;
            if (t) [made addObject:t];
            else if (why) lastWhy = why;
            if (--pending > 0) return;
            [ss albumImportFinished:made lastWhy:lastWhy total:n];
        });
    };

    for (PHPickerResult *r in results) {
        NSItemProvider *ip = r.itemProvider;
        if (!ip || ![ip canLoadObjectOfClass:[UIImage class]]) {
            FUSLog(@"album item cannot load a UIImage");
            step(nil, @"有一张读不出来");
            continue;
        }
        dispatch_queue_t workQ = _queue;
        [ip loadObjectOfClass:[UIImage class]
            completionHandler:^(__kindof id<NSItemProviderReading> obj, NSError *err) {
            UIImage *img = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
            if (err || !img) {
                FUSLog(@"album load failed: %@", err);
                step(nil, @"有一张读不出来");
                return;
            }
            dispatch_async(workQ, ^{
                @autoreleasepool {
                    NSString *why = nil;
                    NSDictionary *t = FUSTemplateFromImage(img, &why);
                    if (!t) FUSLog(@"album reject: %@", why);
                    step(t, why);
                }
            });
        }];
    }

    // a provider that never calls back must not lock the album button forever
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || !ss->_albumRunning) return;
        FUSLog(@"album watchdog: %lu of %lu item(s) never reported",
               (unsigned long)pending, (unsigned long)n);
        [ss albumImportFinished:made lastWhy:lastWhy total:n];
    });
}

- (void)albumImportFinished:(NSArray *)made lastWhy:(NSString *)why total:(NSUInteger)total {
    if (!_albumRunning) return;      // already reported (watchdog beat us here)
    _albumRunning = NO;
    _albumDone = made.count;
    _albumBad  = (total > made.count) ? (total - made.count) : 0;
    for (NSDictionary *t in made) [_collected addObject:t];
    FUSLog(@"album import: %lu/%lu good, total samples %lu",
           (unsigned long)made.count, (unsigned long)total,
           (unsigned long)_collected.count);
    [self publishMeter];

    if (_collected.count >= kSamples) {
        _finished = YES;
        [self finish];
        return;
    }
    [self refreshManualUI];
    if (made.count > 0) {
        [self setHint:[NSString stringWithFormat:
            @"成功 %lu 张 · 现在共 %lu/%lu\n可以继续选，或点右边「保存 %lu 张」直接完成",
            (unsigned long)made.count, (unsigned long)_collected.count,
            (unsigned long)kSamples, (unsigned long)_collected.count]];
    } else {
        [self setHint:[NSString stringWithFormat:
            @"这一批一张都没成：%@\n换几张清晰正面自拍（光线亮点、别侧头）再试",
            why ?: @"没检测到人脸"]];
    }
}

#pragma mark - camera: system UI (cannot fail)

- (void)uiManualOnly {
    void (^b)(void) = ^{
        if (self->_finished || self->_manualMode) return;
        [self stopPhotoPump];
        self->_manualButton.hidden = NO;
        [self->_manualButton setTitle:@"① 从相册选照片（推荐）" forState:UIControlStateNormal];
        self->_manualButton.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.85 alpha:1];
        self->_hintLabel.text = @"这台设备上 App 拿不到任何一帧画面（视频和拍照都是）\n"
                                @"请点左边蓝色按钮「从相册选照片」";
        [self publishMeter];
    };
    if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
}

- (void)manualTapped:(UIButton *)b {
    if (_finished) return;
    if (_pickerUp) return;
    // The album (left, big) is the reliable route; this is the live-camera one.
    // The in-app shutter is kept because it is the only path that captures a
    // fresh sample on devices where AVCapturePhotoOutput does answer.
    [self openShutter];
}

#pragma mark - in-app shutter (the only camera UI that works here)

- (void)openShutter {
    if (_finished) return;
    FUSLog(@"openShutter (collected %lu)", (unsigned long)_collected.count);
    _manualMode = YES;
    _manualButton.hidden = NO;
    _sourceNote = @"App 快门";
    _linkNote   = @"in-app";
    [self stopPhotoPump];
    [self publishMeter];
    [self setHint:@"正在打开相机…"];

    __weak FUSEnrollViewController *weakSelf = self;
    [self teardownSessionThen:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf presentShutter];
        });
    }];
}

- (void)presentShutter {
    if (_finished) { _manualMode = NO; return; }
    if (!self.view.window) {
        _manualMode = NO;
        [self setHint:@"页面不在前台，无法打开相机"];
        return;
    }
    if (self.presentedViewController) {
        FUSLog(@"presentShutter blocked by %@ (retry %lu)",
               self.presentedViewController, (unsigned long)_presentRetries);
        if (++_presentRetries <= 4) {
            __weak FUSEnrollViewController *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [ws presentShutter]; });
        } else {
            _presentRetries = 0;
            [self setHint:@"相机页没能打开（页面还盖着别的东西）\n点左边按钮再试"];
            [self refreshManualUI];
        }
        return;
    }
    _presentRetries = 0;

    FUSShotViewController *sh = [FUSShotViewController new];
    __weak FUSEnrollViewController *weakSelf = self;
    sh.onClose = ^(NSArray *tpls) {
        FUSEnrollViewController *ss = weakSelf;
        if (!ss) return;
        [ss handleShutterClosedWith:tpls];
    };
    FUSLog(@"presenting the in-app shutter");
    [self presentViewController:sh animated:YES completion:nil];
}

- (void)handleShutterClosedWith:(NSArray *)tpls {
    if (_finished) return;
    NSUInteger added = 0;
    if ([tpls isKindOfClass:[NSArray class]] && tpls.count > 0) {
        for (NSDictionary *t in tpls) {
            if (![t isKindOfClass:[NSDictionary class]]) continue;
            [_collected addObject:t];
            added++;
        }
    }
    FUSLog(@"shutter closed: +%lu samples, total %lu", (unsigned long)added,
           (unsigned long)_collected.count);
    if (_collected.count >= kSamples) {
        _finished = YES;
        [self finish];
        return;
    }
    [self refreshManualUI];
    if (added > 0) {
        [self setHint:[NSString stringWithFormat:
            @"已采集 %lu/%lu\n点右边「保存 %lu 张」就能完成（少几张也能用）",
            (unsigned long)_collected.count, (unsigned long)kSamples,
            (unsigned long)_collected.count]];
    } else {
        [self setHint:[NSString stringWithFormat:
            @"相机这条路还是没给画面 · 总计 %lu/%lu\n点左边蓝色按钮改用相册导入",
            (unsigned long)_collected.count, (unsigned long)kSamples]];
    }
}

// Opens the album picker (and only that — the system camera UI is replaced by
// FUSShotViewController, see above).
- (void)openPicker:(UIImagePickerControllerSourceType)src {
    if (_finished) return;
    if (_pickerUp) return;
    if (src == UIImagePickerControllerSourceTypeCamera) {
        // safety net: the system camera must never be presented again
        [self openShutter];
        return;
    }
    if (![UIImagePickerController isSourceTypeAvailable:src]) {
        [self failWith:@"这台设备没有可用的相册"];
        return;
    }
    FUSLog(@"openPicker src=%ld (collected %lu)", (long)src,
           (unsigned long)_collected.count);
    _manualMode = YES;
    _manualButton.hidden = NO;
    _sourceNote = @"相册";
    _linkNote   = @"system UI";
    [self stopPhotoPump];
    [self publishMeter];
    [self setHint:@"正在打开相册…"];

    __weak FUSEnrollViewController *weakSelf = self;
    [self teardownSessionThen:^{
        // stopRunning returns before the camera hardware is fully released.
        // Handing a still-releasing device to the picker is exactly what
        // leaves its shutter greyed out, so wait a beat.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf presentPicker:src];
        });
    }];
}

- (void)presentPicker:(UIImagePickerControllerSourceType)src {
    if (_finished) { _manualMode = NO; return; }
    if (_pickerUp) return;
    if (!self.view.window) {
        FUSLog(@"enroll view is not in a window, cannot present the picker");
        _manualMode = NO;
        [self setHint:@"页面已经不在前台，无法打开相机"];
        return;
    }
    if (self.presentedViewController) {
        // An action sheet or the previous picker may still be animating away.
        // Silently giving up here is how the screen ends up with no way
        // forward, so retry a few times before saying anything.
        FUSLog(@"still presenting %@ (retry %lu)",
               self.presentedViewController, (unsigned long)_presentRetries);
        _pickerUp = NO;
        if (++_presentRetries <= 4) {
            __weak FUSEnrollViewController *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [ws presentPicker:src]; });
        } else {
            _presentRetries = 0;
            [self setHint:@"相机界面没能打开（页面还盖着别的东西）\n点左边按钮再试一次"];
            [self refreshManualUI];
        }
        return;
    }
    _presentRetries = 0;
    _pickerUp = YES;
    UIImagePickerController *p = [UIImagePickerController new];
    p.sourceType = src;
    p.allowsEditing = NO;
    p.delegate = self;
    FUSLog(@"presenting album picker");
    [self presentViewController:p animated:YES completion:^{
        FUSLog(@"album picker is up");
    }];

    // If the picker never actually becomes the presented controller, say so
    // instead of leaving a dead screen.
    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || ss->_finished) return;
        if (ss.presentedViewController == p) return;
        if (!ss->_pickerUp) return;
        FUSLog(@"album picker never came up");
        ss->_pickerUp = NO;
        [ss setHint:@"相册没能打开\n点左边按钮重试，或用右边按钮先完成录入"];
        [ss refreshManualUI];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<NSString *, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    _pickerUp = NO;
    FUSLog(@"system camera returned %@ image",
           [img isKindOfClass:[UIImage class]] ? NSStringFromCGSize(img.size) : @"nil");

    __weak FUSEnrollViewController *weakSelf = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || ss->_finished) return;
        [ss handleManualImage:img];
    }];
}

- (void)handleManualImage:(UIImage *)img {
    if (_finished) return;
    if (![img isKindOfClass:[UIImage class]]) {
        [self setHint:@"系统相机没有返回照片\n请再拍一次"];
        [self refreshManualUI];
        return;
    }
    [self setHint:@"收到照片，正在识别…"];
    [self publishMeter];

    CVPixelBufferRef pb = FUSPixelBufferFromImage(img);
    if (!pb) {
        FUSLog(@"could not convert the still to a pixel buffer");
        [self setHint:@"这张照片转换失败\n请再拍一次（正对镜头、光线亮一点）"];
        [self refreshManualUI];
        return;
    }

    NSUInteger before = _collected.count;
    __weak FUSEnrollViewController *weakSelf = self;
    dispatch_async(_queue, ^{
        @autoreleasepool {
            FUSEnrollViewController *ss = weakSelf;
            if (!ss) { CVPixelBufferRelease(pb); return; }
            ss->_lastCapture = nil;          // manual shots are never "too soon"
            ss->_framesSeen++;
            [ss processPixelBuffer:pb];
            CVPixelBufferRelease(pb);
            dispatch_async(dispatch_get_main_queue(), ^{
                FUSEnrollViewController *s2 = weakSelf;
                if (!s2 || s2->_finished) return;
                if (s2->_collected.count >= kSamples) return;
                if (s2->_collected.count > before) {
                    [s2 rearmManual];
                } else {
                    // the shot was rejected: keep the reason that
                    // processPixelBuffer just put on screen, only refresh the
                    // buttons so there is still a way forward
                    [s2 refreshManualUI];
                }
            });
        }
    });
}

// After each shot: refresh the two buttons and stop.  We deliberately do NOT
// re-open the picker automatically — a picker that pops up by itself with a
// dead shutter is exactly the "the shutter button won't press" report.  The
// user taps 「再拍一张」 when ready, and that menu also offers the album.
- (void)refreshManualUI {
    if (!_manualMode || _finished) return;
    NSUInteger n = _collected.count;
    [_manualButton setTitle:(n > 0
            ? [NSString stringWithFormat:@"① 继续选照片（已 %lu/%lu）",
                                         (unsigned long)n, (unsigned long)kSamples]
            : @"① 从相册选照片（推荐）")
                   forState:UIControlStateNormal];
    _manualButton.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.85 alpha:1];
    if (n > 0) {
        _retryButton.hidden = NO;
        [_retryButton setTitle:[NSString stringWithFormat:@"保存 %lu 张",
                                (unsigned long)n]
                      forState:UIControlStateNormal];
    }
}

- (void)rearmManual {
    if (_finished || !_manualMode) return;
    [self refreshManualUI];
    NSUInteger n = _collected.count;
    if (n >= kSamples) return;
    [self setHint:[NSString stringWithFormat:
        @"已采集 %lu/%lu\n点左边继续选照片，或点右边直接保存",
        (unsigned long)n, (unsigned long)kSamples]];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    _pickerUp = NO;
    __weak FUSEnrollViewController *weakSelf = self;
    // _manualMode stays YES: the two on-screen buttons are now the only way
    // forward, and the viewDidAppear triggered by this dismissal must not
    // restart the capture session underneath the animation.
    [picker dismissViewControllerAnimated:YES completion:^{
        FUSEnrollViewController *ss = weakSelf;
        if (!ss || ss->_finished) return;
        [ss refreshManualUI];
        NSUInteger n = ss->_collected.count;
        if (n > 0) {
            [ss setHint:[NSString stringWithFormat:
                @"已取消 · 已采集 %lu/%lu\n点左边继续选，或点右边「保存 %lu 张」",
                (unsigned long)n, (unsigned long)kSamples, (unsigned long)n]];
        } else {
            [ss setHint:@"已取消 · 还没采到样本\n点左边「从相册选照片」再来"];
        }
    }];
}

- (void)stopCamera {
    [self stopPhotoPump];
    [self teardownSessionThen:nil];
}

- (void)failWith:(NSString *)msg {
    FUSLog(@"enroll failure: %@", msg);
    _building = NO;
    _hintLabel.text = msg;
    _retryButton.hidden = NO;
    _manualButton.hidden = NO;
}

- (void)retryTapped:(UIButton *)b {
    // In the system-camera flow this button doubles as "finish with what I
    // already have".  The picker's shutter can die after the first shot, so a
    // single good sample must be enough to save — otherwise enrollment has no
    // exit at all.
    if (_manualMode && _collected.count > 0) {
        FUSLog(@"finishing the manual flow with %lu sample(s)",
               (unsigned long)_collected.count);
        _finished = YES;
        [self stopPhotoPump];
        _pickerUp   = NO;
        _manualMode = NO;
        if (self.presentedViewController) {
            [self.presentedViewController dismissViewControllerAnimated:NO completion:nil];
        }
        [self finish];
        return;
    }

    FUSLog(@"retry tapped");
    [self stopPhotoPump];
    _manualMode = NO;
    _pickerUp   = NO;
    _finished   = NO;
    _photoMode  = NO;
    _photoFails = 0;
    _photoShots = 0;
    _framesSeen = 0;
    _framesAtStart = 0;
    _detectRuns = 0;
    _faceHits   = 0;
    _dropsSeen  = 0;
    _lastCapture = nil;
    _sourceNote = @"等待相机";
    _linkNote   = @"-";
    [_collected removeAllObjects];
    _progressLabel.text = @"0 / 5";
    _retryButton.hidden = YES;
    _manualButton.hidden = NO;
    _hintLabel.text = @"正在重试…";

    __weak FUSEnrollViewController *weakSelf = self;
    [self teardownSessionThen:^{
        [weakSelf startCamera];
    }];
}

- (void)cancelTapped:(UIButton *)b {
    FUSLog(@"cancel tapped (collected %lu)", (unsigned long)_collected.count);
    if (_collected.count > 0 && _collected.count < kSamples) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"还没录完"
                             message:[NSString stringWithFormat:
                                 @"已经采集 %lu/%lu，现在退出不会保存。",
                                 (unsigned long)_collected.count, (unsigned long)kSamples]
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"继续录入" style:UIAlertActionStyleCancel handler:nil]];
        __weak FUSEnrollViewController *weakSelf = self;
        [a addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) { [weakSelf dismissSelf]; }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self dismissSelf];
}

- (void)dismissSelf {
    _manualMode = NO;
    _pickerUp   = NO;
    _finished   = YES;      // stop every pending callback from touching the UI
    [self stopCamera];
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
        @"帧 %lu 检测 %lu 命中 %lu · %@",
        (unsigned long)_framesSeen, (unsigned long)_detectRuns,
        (unsigned long)_faceHits, _sourceNote ?: @"-"];
    NSString *line2 = [NSString stringWithFormat:
        @"%lux%lu 丢%lu 快门%lu 失败%lu",
        (unsigned long)_bufW, (unsigned long)_bufH, (unsigned long)_dropsSeen,
        (unsigned long)_photoShots, (unsigned long)_photoFails];
    NSString *line3 = [NSString stringWithFormat:@"%@ · %@",
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
            FUSLog(@"first video frame arrived - the stream is alive, still pump off");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self stopPhotoPump];
                self->_sourceNote = @"视频";
                [self publishMeter];
            });
        }
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pb) return;
        [self processPixelBuffer:pb];
    }
}

// Delegate too slow / starved: AVFoundation reports discarded buffers here.
- (void)captureOutput:(AVCaptureOutput *)output
didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    _dropsSeen++;
    if (_dropsSeen == 1 || _dropsSeen % 25 == 0) {
        FUSLog(@"dropped buffers: %lu (video frames seen %lu)",
               (unsigned long)_dropsSeen, (unsigned long)_framesSeen);
    }
}

- (void)photoOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
              error:(NSError *)error {
    _photoInFlight = NO;
    if (error) {
        _photoFails++;
        FUSLog(@"still error: %@", error.localizedDescription ?: @"?");
        [self publishMeter];
        if (_photoFails >= 3) [self uiManualOnly];
        return;
    }

    CVPixelBufferRef pb = photo.pixelBuffer;
    if (pb) {
        _photoShots++;
        _photoFails = 0;
        CVPixelBufferRetain(pb);
        __weak FUSEnrollViewController *weakSelf = self;
        dispatch_async(_queue, ^{
            @autoreleasepool {
                FUSEnrollViewController *ss = weakSelf;
                if (!ss) { CVPixelBufferRelease(pb); return; }
                ss->_framesSeen++;
                [ss processPixelBuffer:pb];
                CVPixelBufferRelease(pb);
            }
        });
        return;
    }

    // processed stills (JPEG) carry no pixel buffer — decode the file instead
    NSData *d = photo.fileDataRepresentation;
    UIImage *img = d ? [UIImage imageWithData:d] : nil;
    CVPixelBufferRef pb2 = img ? FUSPixelBufferFromImage(img) : NULL;
    if (!pb2) {
        _photoFails++;
        FUSLog(@"still had neither a pixel buffer nor decodable data (fails %lu)",
               (unsigned long)_photoFails);
        [self publishMeter];
        if (_photoFails >= 3) [self uiManualOnly];
        return;
    }
    _photoShots++;
    _photoFails = 0;
    __weak FUSEnrollViewController *weakSelf2 = self;
    dispatch_async(_queue, ^{
        @autoreleasepool {
            FUSEnrollViewController *ss = weakSelf2;
            if (!ss) { CVPixelBufferRelease(pb2); return; }
            ss->_framesSeen++;
            [ss processPixelBuffer:pb2];
            CVPixelBufferRelease(pb2);
        }
    });
}

// Runs on _queue (serial) for every frame source (video / still / system
// camera), so the sampling logic is shared and two sources cannot interleave.
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
        // enrollable.  The tweak uses the same setting, so both sides accept
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
            if (self->_manualMode) [self refreshManualUI];
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
    NSUInteger n = _collected.count;
    FUSLog(@"finish: saving %lu templates", (unsigned long)n);
    _finished = YES;
    // dismiss any picker still on screen before the save-alert goes up
    if (self.presentedViewController) {
        [self.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    }
    _pickerUp = NO;
    _manualMode = NO;
    [self stopCamera];

    // never overwrite a good template set with nothing
    if (n == 0) {
        _finished = NO;
        [self failWith:@"还没采到任何样本\n请点「从相册选照片」再来一次"];
        return;
    }

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
    NSString *msg = (n >= kSamples)
        ? @"已保存 5 个人脸样本。\n现在锁屏，把脸对准前置摄像头即可解锁。\n\n如果没反应，回到 App 首页看「当前状态」那一行。"
        : [NSString stringWithFormat:
            @"只保存了 %lu 个样本（目标是 5 个）。\n现在锁屏就能试。\n如果经常认不出，回 App 点「继续选照片 / 保存」补齐。",
            (unsigned long)n];
    [self dismissViewControllerAnimated:YES completion:^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"录入完成"
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [weakPresenter presentViewController:a animated:YES completion:nil];
    }];
}

@end