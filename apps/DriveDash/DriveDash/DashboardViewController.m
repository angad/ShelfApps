#import "DashboardViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <math.h>

typedef NS_ENUM(NSInteger, DDSpeedUnit) {
    DDSpeedUnitMPH = 0,
    DDSpeedUnitKMH = 1
};

static NSString * const DDTripHistoryKey = @"DriveDash.TripHistory";
static const CLLocationSpeed DDStationarySpeedThreshold = 2.24; // 5 mph
static const CLLocationAccuracy DDGoodHorizontalAccuracy = 35.0;
static const CLLocationAccuracy DDFairHorizontalAccuracy = 65.0;
static const NSTimeInterval DDFreshLocationAge = 12.0;
static const NSTimeInterval DDGPSRetryInterval = 10.0;
static const NSTimeInterval DDGPSNoFixWarningInterval = 20.0;
static const NSTimeInterval DDGPSPoorSkyWarningInterval = 60.0;

@interface DDMetricView : UIView

- (instancetype)initWithTitle:(NSString *)title;
- (void)updateValue:(NSString *)value subtitle:(NSString *)subtitle;

@end

@interface DDGMeterView : UIView

- (void)updateLateral:(double)lateral forward:(double)forward;

@end

@interface DashboardViewController () <CLLocationManagerDelegate>

@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) CMMotionManager *motionManager;
@property (nonatomic, strong) NSTimer *tickTimer;

@property (nonatomic) DDSpeedUnit unit;
@property (nonatomic) BOOL hudMode;
@property (nonatomic, strong) NSDate *startDate;
@property (nonatomic, strong) NSDate *lastTickDate;
@property (nonatomic, strong) CLLocation *lastLocation;
@property (nonatomic, strong) CLLocation *currentLocation;
@property (nonatomic, strong) NSDate *lastLocationUpdateDate;
@property (nonatomic, strong) NSDate *locationStartDate;
@property (nonatomic, strong) NSDate *lastLocationRequestDate;
@property (nonatomic, copy) NSString *locationMessage;
@property (nonatomic) CLLocationSpeed lastGoodSpeed;
@property (nonatomic) CLLocationDistance distanceMeters;
@property (nonatomic) CLLocationSpeed maxSpeedMetersPerSecond;
@property (nonatomic) NSTimeInterval movingSeconds;
@property (nonatomic) NSTimeInterval stoppedSeconds;
@property (nonatomic) CLLocationDirection headingDegrees;
@property (nonatomic) double latestForwardG;
@property (nonatomic) double latestLateralG;
@property (nonatomic) double peakAccelG;
@property (nonatomic) double peakBrakeG;
@property (nonatomic) double peakLeftG;
@property (nonatomic) double peakRightG;
@property (nonatomic) double calibrationForwardG;
@property (nonatomic) double calibrationLateralG;

@property (nonatomic, strong) UIView *dashboardPanel;
@property (nonatomic, strong) UILabel *clockLabel;
@property (nonatomic, strong) UILabel *signalLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UILabel *speedUnitLabel;
@property (nonatomic, strong) UILabel *headingLabel;
@property (nonatomic, strong) UILabel *headingDetailLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) DDMetricView *tripDistanceMetric;
@property (nonatomic, strong) DDMetricView *avgSpeedMetric;
@property (nonatomic, strong) DDMetricView *maxSpeedMetric;
@property (nonatomic, strong) DDMetricView *tripTimeMetric;
@property (nonatomic, strong) DDMetricView *coordsMetric;
@property (nonatomic, strong) DDMetricView *altitudeMetric;
@property (nonatomic, strong) DDMetricView *satelliteMetric;
@property (nonatomic, strong) DDMetricView *temperatureMetric;
@property (nonatomic, strong) DDMetricView *accuracyMetric;
@property (nonatomic, strong) DDMetricView *gPeakMetric;
@property (nonatomic, strong) DDGMeterView *gMeterView;
@property (nonatomic, strong) UIButton *hudButton;
@property (nonatomic, strong) UIButton *flashlightButton;
@property (nonatomic) BOOL flashlightOn;

@end

@implementation DashboardViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _unit = DDSpeedUnitMPH;
        _headingDegrees = -1;
        _startDate = [NSDate date];
        _lastTickDate = [NSDate date];
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [self colorBackground];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    [self buildInterface];
    [self configureLocation];
    [self configureMotion];
    [self startTimers];
    [self render];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.tickTimer invalidate];
    [self.motionManager stopDeviceMotionUpdates];
    [self.locationManager stopUpdatingLocation];
    [self.locationManager stopUpdatingHeading];
    [self applyFlashlightEnabled:NO];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)buildInterface {
    UIStackView *root = [[UIStackView alloc] init];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 6;
    root.layoutMargins = UIEdgeInsetsMake(7, 10, 7, 10);
    root.layoutMarginsRelativeArrangement = YES;
    [self.view addSubview:root];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]
    ]];

    [root addArrangedSubview:[self headerView]];
    [root addArrangedSubview:[self dashboardView]];
    [root addArrangedSubview:[self tripStatsView]];
    [root addArrangedSubview:[self controlsView]];
}

- (UIView *)headerView {
    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.distribution = UIStackViewDistributionEqualSpacing;
    [header.heightAnchor constraintEqualToConstant:30].active = YES;

    UILabel *title = [self labelWithSize:16 weight:UIFontWeightBlack color:[self colorAccent]];
    title.text = @"DRIVEDASH";
    [title setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.clockLabel = [self labelWithSize:22 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.92 alpha:1.0]];
    self.signalLabel = [self labelWithSize:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    self.batteryLabel = [self labelWithSize:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    self.signalLabel.textAlignment = NSTextAlignmentRight;
    self.batteryLabel.textAlignment = NSTextAlignmentRight;
    [self.clockLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[self.signalLabel, self.batteryLabel]];
    right.axis = UILayoutConstraintAxisHorizontal;
    right.spacing = 10;
    right.alignment = UIStackViewAlignmentCenter;

    [header addArrangedSubview:title];
    [header addArrangedSubview:self.clockLabel];
    [header addArrangedSubview:right];
    return header;
}

- (UIView *)dashboardView {
    self.dashboardPanel = [[UIView alloc] init];
    self.dashboardPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.dashboardPanel.backgroundColor = [self colorPanel];
    self.dashboardPanel.layer.cornerRadius = 8;
    self.dashboardPanel.clipsToBounds = YES;

    UIStackView *content = [[UIStackView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentFill;
    content.distribution = UIStackViewDistributionFill;
    content.spacing = 10;
    content.layoutMargins = UIEdgeInsetsMake(8, 12, 8, 12);
    content.layoutMarginsRelativeArrangement = YES;
    [self.dashboardPanel addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.dashboardPanel.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.dashboardPanel.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.dashboardPanel.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.dashboardPanel.bottomAnchor]
    ]];

    self.speedLabel = [self labelWithSize:116 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    self.speedLabel.textAlignment = NSTextAlignmentLeft;
    self.speedLabel.minimumScaleFactor = 0.42;
    self.speedLabel.lineBreakMode = NSLineBreakByClipping;
    self.speedUnitLabel = [self labelWithSize:20 weight:UIFontWeightBold color:[self colorAccent]];
    self.statusLabel = [self labelWithSize:11 weight:UIFontWeightBold color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    self.statusLabel.numberOfLines = 1;
    self.statusLabel.textAlignment = NSTextAlignmentLeft;

    UIStackView *unitStatus = [[UIStackView alloc] initWithArrangedSubviews:@[self.speedUnitLabel, self.statusLabel]];
    unitStatus.axis = UILayoutConstraintAxisHorizontal;
    unitStatus.spacing = 10;
    unitStatus.alignment = UIStackViewAlignmentFirstBaseline;
    [self.speedUnitLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *speedStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.speedLabel, unitStatus]];
    speedStack.axis = UILayoutConstraintAxisVertical;
    speedStack.alignment = UIStackViewAlignmentLeading;
    speedStack.spacing = 0;
    [content addArrangedSubview:speedStack];
    [speedStack.widthAnchor constraintEqualToAnchor:content.widthAnchor multiplier:0.40].active = YES;

    self.headingLabel = [self labelWithSize:46 weight:UIFontWeightBold color:[UIColor whiteColor]];
    self.headingDetailLabel = [self labelWithSize:14 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    self.headingLabel.textAlignment = NSTextAlignmentCenter;
    self.headingDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.coordsMetric = [[DDMetricView alloc] initWithTitle:@"COORDS"];
    self.altitudeMetric = [[DDMetricView alloc] initWithTitle:@"ALT"];

    UIStackView *middle = [[UIStackView alloc] initWithArrangedSubviews:@[self.headingLabel, self.headingDetailLabel, self.coordsMetric, self.altitudeMetric]];
    middle.axis = UILayoutConstraintAxisVertical;
    middle.spacing = 8;
    middle.alignment = UIStackViewAlignmentFill;
    [content addArrangedSubview:middle];
    [self.coordsMetric.heightAnchor constraintEqualToConstant:42].active = YES;
    [self.altitudeMetric.heightAnchor constraintEqualToConstant:42].active = YES;

    self.gMeterView = [[DDGMeterView alloc] init];
    self.accuracyMetric = [[DDMetricView alloc] initWithTitle:@"GPS"];
    self.satelliteMetric = [[DDMetricView alloc] initWithTitle:@"SAT"];
    self.temperatureMetric = [[DDMetricView alloc] initWithTitle:@"TEMP"];
    self.gPeakMetric = [[DDMetricView alloc] initWithTitle:@"PEAK G"];

    UIStackView *fixStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.accuracyMetric, self.temperatureMetric]];
    fixStack.axis = UILayoutConstraintAxisHorizontal;
    fixStack.spacing = 6;
    fixStack.distribution = UIStackViewDistributionFillEqually;

    UIStackView *auxStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.satelliteMetric, self.gPeakMetric]];
    auxStack.axis = UILayoutConstraintAxisHorizontal;
    auxStack.spacing = 6;
    auxStack.distribution = UIStackViewDistributionFillEqually;

    UIStackView *gStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.gMeterView, fixStack, auxStack]];
    gStack.axis = UILayoutConstraintAxisVertical;
    gStack.spacing = 5;
    gStack.alignment = UIStackViewAlignmentFill;
    [content addArrangedSubview:gStack];
    [gStack.widthAnchor constraintEqualToAnchor:content.widthAnchor multiplier:0.27].active = YES;
    [self.gMeterView.heightAnchor constraintGreaterThanOrEqualToConstant:70].active = YES;
    [fixStack.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [auxStack.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;

    return self.dashboardPanel;
}

- (UIView *)tripStatsView {
    self.tripDistanceMetric = [[DDMetricView alloc] initWithTitle:@"TRIP"];
    self.avgSpeedMetric = [[DDMetricView alloc] initWithTitle:@"AVG"];
    self.maxSpeedMetric = [[DDMetricView alloc] initWithTitle:@"MAX"];
    self.tripTimeMetric = [[DDMetricView alloc] initWithTitle:@"TIME"];

    UIStackView *stats = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.tripDistanceMetric,
        self.avgSpeedMetric,
        self.maxSpeedMetric,
        self.tripTimeMetric
    ]];
    stats.axis = UILayoutConstraintAxisHorizontal;
    stats.spacing = 8;
    stats.distribution = UIStackViewDistributionFillEqually;
    [stats.heightAnchor constraintEqualToConstant:68].active = YES;
    return stats;
}

- (UIView *)controlsView {
    UIButton *resetButton = [self buttonWithTitle:@"RESET"];
    UIButton *unitsButton = [self buttonWithTitle:@"UNITS"];
    self.hudButton = [self buttonWithTitle:@"HUD"];
    UIButton *calibrateButton = [self buttonWithTitle:@"CAL"];
    self.flashlightButton = [self buttonWithTitle:@"LIGHT"];

    [resetButton addTarget:self action:@selector(resetTrip) forControlEvents:UIControlEventTouchUpInside];
    [unitsButton addTarget:self action:@selector(toggleUnits) forControlEvents:UIControlEventTouchUpInside];
    [self.hudButton addTarget:self action:@selector(toggleHUD) forControlEvents:UIControlEventTouchUpInside];
    [calibrateButton addTarget:self action:@selector(calibrateMotion) forControlEvents:UIControlEventTouchUpInside];
    [self.flashlightButton addTarget:self action:@selector(toggleFlashlight) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[resetButton, unitsButton, self.hudButton, calibrateButton, self.flashlightButton]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.spacing = 6;
    controls.distribution = UIStackViewDistributionFillEqually;
    [controls.heightAnchor constraintEqualToConstant:40].active = YES;
    return controls;
}

- (void)configureLocation {
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    self.locationManager.distanceFilter = kCLDistanceFilterNone;
    self.locationManager.headingFilter = 1;
    self.locationManager.activityType = CLActivityTypeAutomotiveNavigation;
    self.locationManager.pausesLocationUpdatesAutomatically = NO;

    if (![CLLocationManager locationServicesEnabled]) {
        self.locationMessage = @"LOCATION OFF";
        [self render];
        return;
    }

    [self handleAuthorization:[CLLocationManager authorizationStatus]];
}

- (void)handleAuthorization:(CLAuthorizationStatus)status {
    switch (status) {
        case kCLAuthorizationStatusNotDetermined:
            self.locationMessage = @"ALLOW GPS";
            [self.locationManager requestWhenInUseAuthorization];
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            [self startLocationUpdates];
            if ([CLLocationManager headingAvailable]) {
                [self.locationManager startUpdatingHeading];
            }
            self.locationMessage = @"GPS STARTING";
            break;
        case kCLAuthorizationStatusDenied:
        case kCLAuthorizationStatusRestricted:
            self.locationMessage = @"ALLOW GPS";
            break;
    }
    [self render];
}

- (void)configureMotion {
    self.motionManager = [[CMMotionManager alloc] init];
    if (!self.motionManager.deviceMotionAvailable) {
        [self.gPeakMetric updateValue:@"--" subtitle:@"MOTION OFF"];
        return;
    }

    self.motionManager.deviceMotionUpdateInterval = 0.08;
    __weak typeof(self) weakSelf = self;
    [self.motionManager startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMDeviceMotion *motion, NSError *error) {
        DashboardViewController *strongSelf = weakSelf;
        if (!strongSelf || !motion) {
            return;
        }

        double forward = motion.userAcceleration.x;
        double lateral = -motion.userAcceleration.y;
        if ([UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationLandscapeRight) {
            forward = -forward;
            lateral = -lateral;
        }

        strongSelf.latestForwardG = forward - strongSelf.calibrationForwardG;
        strongSelf.latestLateralG = lateral - strongSelf.calibrationLateralG;
        [strongSelf updatePeaks];
        [strongSelf.gMeterView updateLateral:strongSelf.latestLateralG forward:strongSelf.latestForwardG];
    }];
}

- (void)startTimers {
    self.lastTickDate = [NSDate date];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)tick {
    NSDate *now = [NSDate date];
    NSTimeInterval delta = [now timeIntervalSinceDate:self.lastTickDate];
    self.lastTickDate = now;

    if (self.lastLocationUpdateDate && [now timeIntervalSinceDate:self.lastLocationUpdateDate] > DDFreshLocationAge) {
        self.lastGoodSpeed = self.lastGoodSpeed > 0.4 ? self.lastGoodSpeed * 0.5 : 0;
    }
    [self updateGPSAcquisitionStateAtDate:now];

    if (self.lastGoodSpeed > 1.0) {
        self.movingSeconds += delta;
    } else {
        self.stoppedSeconds += delta;
    }

    [self render];
}

- (void)resetTrip {
    [self saveCurrentTripIfNeeded];
    self.startDate = [NSDate date];
    self.lastLocation = nil;
    self.currentLocation = nil;
    self.lastLocationUpdateDate = nil;
    self.locationStartDate = [NSDate date];
    self.lastLocationRequestDate = nil;
    self.locationMessage = @"GPS STARTING";
    self.lastGoodSpeed = 0;
    self.distanceMeters = 0;
    self.maxSpeedMetersPerSecond = 0;
    self.movingSeconds = 0;
    self.stoppedSeconds = 0;
    self.peakAccelG = 0;
    self.peakBrakeG = 0;
    self.peakLeftG = 0;
    self.peakRightG = 0;
    [self render];
}

- (void)startLocationUpdates {
    self.locationStartDate = [NSDate date];
    self.lastLocationRequestDate = nil;
    [self.locationManager startUpdatingLocation];
    [self requestSingleLocationIfNeededAtDate:self.locationStartDate force:YES];
}

- (void)requestSingleLocationIfNeededAtDate:(NSDate *)now force:(BOOL)force {
    if (!force && self.lastLocationRequestDate && [now timeIntervalSinceDate:self.lastLocationRequestDate] < DDGPSRetryInterval) {
        return;
    }
    self.lastLocationRequestDate = now;
    if ([self.locationManager respondsToSelector:@selector(requestLocation)]) {
        [self.locationManager requestLocation];
    }
}

- (void)updateGPSAcquisitionStateAtDate:(NSDate *)now {
    CLAuthorizationStatus status = [CLLocationManager authorizationStatus];
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.locationMessage = @"ALLOW GPS";
        return;
    }
    if (status == kCLAuthorizationStatusNotDetermined) {
        self.locationMessage = @"ALLOW GPS";
        return;
    }
    if (![CLLocationManager locationServicesEnabled]) {
        self.locationMessage = @"LOCATION OFF";
        return;
    }
    if (self.currentLocation) {
        return;
    }

    if (!self.locationStartDate) {
        self.locationStartDate = now;
    }

    [self requestSingleLocationIfNeededAtDate:now force:NO];
    NSTimeInterval waitingSeconds = [now timeIntervalSinceDate:self.locationStartDate];
    if (waitingSeconds >= DDGPSPoorSkyWarningInterval) {
        self.locationMessage = @"NEED SKY";
    } else if (waitingSeconds >= DDGPSNoFixWarningInterval) {
        self.locationMessage = @"NO GPS FIX";
    } else {
        self.locationMessage = @"GPS STARTING";
    }
}

- (void)toggleUnits {
    self.unit = self.unit == DDSpeedUnitMPH ? DDSpeedUnitKMH : DDSpeedUnitMPH;
    [self render];
}

- (void)toggleHUD {
    self.hudMode = !self.hudMode;
    self.dashboardPanel.transform = self.hudMode ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
    [self.hudButton setTitle:(self.hudMode ? @"HUD ON" : @"HUD") forState:UIControlStateNormal];
}

- (void)calibrateMotion {
    self.calibrationForwardG += self.latestForwardG;
    self.calibrationLateralG += self.latestLateralG;
    self.latestForwardG = 0;
    self.latestLateralG = 0;
    [self.gMeterView updateLateral:0 forward:0];
}

- (void)toggleFlashlight {
    [self applyFlashlightEnabled:!self.flashlightOn];
}

- (void)applyFlashlightEnabled:(BOOL)on {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device || !device.hasTorch) {
        _flashlightOn = NO;
        [self updateFlashlightButtonWithMessage:@"NO LED"];
        return;
    }

    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        _flashlightOn = NO;
        [self updateFlashlightButtonWithMessage:@"LIGHT"];
        return;
    }

    if (on && [device isTorchModeSupported:AVCaptureTorchModeOn]) {
        device.torchMode = AVCaptureTorchModeOn;
        _flashlightOn = YES;
    } else {
        device.torchMode = AVCaptureTorchModeOff;
        _flashlightOn = NO;
    }
    [device unlockForConfiguration];
    [self updateFlashlightButtonWithMessage:nil];
}

- (void)updateFlashlightButtonWithMessage:(NSString *)message {
    NSString *title = message ?: (self.flashlightOn ? @"LIT" : @"LIGHT");
    [self.flashlightButton setTitle:title forState:UIControlStateNormal];
    self.flashlightButton.backgroundColor = self.flashlightOn ? [self colorAccent] : [self colorControl];
    self.flashlightButton.tintColor = self.flashlightOn ? [UIColor blackColor] : [UIColor whiteColor];
}

- (void)updatePeaks {
    self.peakAccelG = MAX(self.peakAccelG, self.latestForwardG);
    self.peakBrakeG = MIN(self.peakBrakeG, self.latestForwardG);
    self.peakLeftG = MIN(self.peakLeftG, self.latestLateralG);
    self.peakRightG = MAX(self.peakRightG, self.latestLateralG);
}

- (void)render {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    self.clockLabel.text = [formatter stringFromDate:[NSDate date]];

    float battery = [UIDevice currentDevice].batteryLevel;
    self.batteryLabel.text = battery >= 0 ? [NSString stringWithFormat:@"BAT %.0f%%", battery * 100] : @"BAT --";

    self.speedLabel.text = [NSString stringWithFormat:@"%.0f", [self displaySpeedFromMetersPerSecond:self.lastGoodSpeed]];
    self.speedUnitLabel.text = [self speedUnitTitle];
    [self.maxSpeedMetric updateValue:[NSString stringWithFormat:@"%.0f", [self displaySpeedFromMetersPerSecond:self.maxSpeedMetersPerSecond]] subtitle:[self speedUnitTitle]];

    double tripDistance = [self displayDistanceFromMeters:self.distanceMeters];
    NSString *distanceFormat = tripDistance < 10 ? @"%.2f" : @"%.1f";
    [self.tripDistanceMetric updateValue:[NSString stringWithFormat:distanceFormat, tripDistance] subtitle:[self distanceUnitTitle]];

    double averageSpeed = self.movingSeconds > 1 ? [self displaySpeedFromMetersPerSecond:(self.distanceMeters / self.movingSeconds)] : 0;
    [self.avgSpeedMetric updateValue:[NSString stringWithFormat:@"%.0f", averageSpeed] subtitle:[self speedUnitTitle]];
    [self.tripTimeMetric updateValue:[self formatDuration:[[NSDate date] timeIntervalSinceDate:self.startDate]] subtitle:@"DRIVE"];

    NSArray<NSString *> *heading = [self headingDisplay];
    self.headingLabel.text = heading[0];
    self.headingDetailLabel.text = heading[1];

    if (self.currentLocation) {
        CLLocation *location = self.currentLocation;
        [self.coordsMetric updateValue:[NSString stringWithFormat:@"%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude] subtitle:@"LAT, LON"];
        if (location.verticalAccuracy >= 0) {
            [self.altitudeMetric updateValue:[NSString stringWithFormat:@"%.0f ft", location.altitude * 3.28084] subtitle:@"ALTITUDE"];
        } else {
            [self.altitudeMetric updateValue:@"--" subtitle:@"ALTITUDE"];
        }
        [self.satelliteMetric updateValue:@"N/A" subtitle:@"NOT PUBLIC"];

        double accuracyFeet = MAX(0, location.horizontalAccuracy) * 3.28084;
        NSString *quality = [self gpsQualityForAccuracy:location.horizontalAccuracy];
        [self.accuracyMetric updateValue:[NSString stringWithFormat:@"%.0f ft", accuracyFeet] subtitle:quality];
        self.signalLabel.text = quality;
        self.statusLabel.text = [self drivingStatusForLocation:location quality:quality];
    } else {
        [self.coordsMetric updateValue:@"--" subtitle:@"WAITING FOR GPS"];
        [self.altitudeMetric updateValue:@"--" subtitle:@"ALTITUDE"];
        [self.satelliteMetric updateValue:@"--" subtitle:@"SAT COUNT"];
        [self.accuracyMetric updateValue:@"--" subtitle:@"GPS"];
        NSString *message = self.locationMessage ?: @"GPS STARTING";
        self.signalLabel.text = message;
        self.statusLabel.text = message;
    }

    [self.temperatureMetric updateValue:@"N/A" subtitle:[self thermalStateSubtitle]];

    double totalG = sqrt((self.latestForwardG * self.latestForwardG) + (self.latestLateralG * self.latestLateralG));
    [self.gPeakMetric updateValue:[NSString stringWithFormat:@"%.2f", totalG] subtitle:[self peakGSubtitle]];
}

- (void)saveCurrentTripIfNeeded {
    NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:self.startDate];
    if (self.distanceMeters <= 160 && duration <= 300) {
        return;
    }

    NSDictionary *summary = @{
        @"startedAt": @([self.startDate timeIntervalSince1970]),
        @"endedAt": @([[NSDate date] timeIntervalSince1970]),
        @"distanceMeters": @(self.distanceMeters),
        @"maxSpeedMetersPerSecond": @(self.maxSpeedMetersPerSecond),
        @"movingSeconds": @(self.movingSeconds)
    };

    NSArray *existing = [[NSUserDefaults standardUserDefaults] objectForKey:DDTripHistoryKey];
    NSMutableArray *trips = existing ? [existing mutableCopy] : [NSMutableArray array];
    [trips insertObject:summary atIndex:0];
    while (trips.count > 25) {
        [trips removeLastObject];
    }
    [[NSUserDefaults standardUserDefaults] setObject:trips forKey:DDTripHistoryKey];
}

- (NSArray<NSString *> *)headingDisplay {
    CLLocationDirection degrees = -1;
    if (self.headingDegrees >= 0) {
        degrees = self.headingDegrees;
    } else if (self.currentLocation.course >= 0) {
        degrees = self.currentLocation.course;
    }

    if (degrees < 0) {
        return @[@"--", @"HEADING"];
    }

    return @[[self compassPointForDegrees:degrees], [NSString stringWithFormat:@"%.0f DEG", degrees]];
}

- (NSString *)gpsQualityForAccuracy:(CLLocationAccuracy)accuracy {
    if (accuracy < 0) {
        return @"GPS LOST";
    }
    if (accuracy <= 15) {
        return @"GPS STRONG";
    }
    if (accuracy <= 50) {
        return @"GPS OK";
    }
    return @"GPS WEAK";
}

- (NSString *)drivingStatusForLocation:(CLLocation *)location quality:(NSString *)quality {
    NSTimeInterval age = fabs([location.timestamp timeIntervalSinceNow]);
    if (age > DDFreshLocationAge) {
        return @"GPS STALE";
    }
    if (location.horizontalAccuracy < 0) {
        return @"GPS LOST";
    }
    if (self.lastGoodSpeed <= 0.01) {
        if (location.horizontalAccuracy > DDFairHorizontalAccuracy) {
            return @"HOLDING 0";
        }
        return @"STOPPED";
    }
    return quality;
}

- (NSString *)peakGSubtitle {
    double brake = fabs(self.peakBrakeG);
    double corner = MAX(fabs(self.peakLeftG), fabs(self.peakRightG));
    return [NSString stringWithFormat:@"A %.2f B %.2f C %.2f", self.peakAccelG, brake, corner];
}

- (NSString *)thermalStateSubtitle {
    NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
    switch (state) {
        case NSProcessInfoThermalStateNominal:
            return @"PHONE OK";
        case NSProcessInfoThermalStateFair:
            return @"PHONE WARM";
        case NSProcessInfoThermalStateSerious:
            return @"PHONE HOT";
        case NSProcessInfoThermalStateCritical:
            return @"COOL DOWN";
    }
    return @"NO AMBIENT";
}

- (NSString *)formatDuration:(NSTimeInterval)interval {
    NSInteger seconds = MAX(0, (NSInteger)interval);
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds % 3600) / 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld", (long)hours, (long)minutes];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)(seconds % 60)];
}

- (NSString *)compassPointForDegrees:(CLLocationDirection)degrees {
    NSArray<NSString *> *points = @[@"N", @"NE", @"E", @"SE", @"S", @"SW", @"W", @"NW"];
    NSInteger index = ((NSInteger)((degrees + 22.5) / 45.0)) & 7;
    return points[index];
}

- (double)displaySpeedFromMetersPerSecond:(double)metersPerSecond {
    double cleanSpeed = MAX(0, metersPerSecond);
    return self.unit == DDSpeedUnitMPH ? cleanSpeed * 2.2369362921 : cleanSpeed * 3.6;
}

- (double)displayDistanceFromMeters:(double)meters {
    return self.unit == DDSpeedUnitMPH ? meters / 1609.344 : meters / 1000.0;
}

- (NSString *)speedUnitTitle {
    return self.unit == DDSpeedUnitMPH ? @"MPH" : @"KM/H";
}

- (NSString *)distanceUnitTitle {
    return self.unit == DDSpeedUnitMPH ? @"MI" : @"KM";
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
    label.textColor = color;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.6;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [self colorControl];
    button.layer.cornerRadius = 7;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.1].CGColor;
    return button;
}

- (UIColor *)colorBackground {
    return [UIColor colorWithRed:0.020 green:0.024 blue:0.026 alpha:1.0];
}

- (UIColor *)colorPanel {
    return [UIColor colorWithRed:0.055 green:0.066 blue:0.074 alpha:1.0];
}

- (UIColor *)colorTile {
    return [UIColor colorWithRed:0.085 green:0.100 blue:0.110 alpha:1.0];
}

- (UIColor *)colorControl {
    return [UIColor colorWithRed:0.110 green:0.130 blue:0.145 alpha:1.0];
}

- (UIColor *)colorAccent {
    return [UIColor colorWithRed:0.430 green:0.910 blue:0.640 alpha:1.0];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    [self handleAuthorization:status];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = [locations lastObject];
    if (!location) {
        return;
    }

    self.currentLocation = location;
    self.lastLocationUpdateDate = [NSDate date];
    self.locationMessage = nil;

    CLLocationSpeed speed = [self filteredSpeedForLocation:location previous:self.lastLocation];
    self.lastGoodSpeed = speed;
    self.maxSpeedMetersPerSecond = MAX(self.maxSpeedMetersPerSecond, speed);

    if ([self shouldAccumulateDistanceForLocation:location previous:self.lastLocation speed:speed]) {
        CLLocationDistance distance = [location distanceFromLocation:self.lastLocation];
        self.distanceMeters += distance;
    }

    self.lastLocation = location;
    [self render];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    CLLocationDirection trueHeading = newHeading.trueHeading;
    self.headingDegrees = trueHeading >= 0 ? trueHeading : newHeading.magneticHeading;
    [self render];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (error.code == kCLErrorDenied) {
        self.locationMessage = @"ALLOW GPS";
    } else if (error.code == kCLErrorLocationUnknown) {
        self.locationMessage = @"GPS SEARCH";
    } else {
        self.locationMessage = @"GPS ERROR";
    }
    [self render];
}

- (CLLocationSpeed)filteredSpeedForLocation:(CLLocation *)location previous:(CLLocation *)previous {
    NSTimeInterval age = fabs([location.timestamp timeIntervalSinceNow]);
    if (age > DDFreshLocationAge || location.horizontalAccuracy < 0) {
        return self.lastGoodSpeed > 0 ? self.lastGoodSpeed * 0.5 : 0;
    }

    CLLocationSpeed reportedSpeed = location.speed >= 0 ? location.speed : 0;
    CLLocationSpeed computedSpeed = [self speedFromLocationPair:previous current:location];
    CLLocationSpeed rawSpeed = reportedSpeed > 0 ? reportedSpeed : computedSpeed;
    CLLocationSpeed speedAccuracy = -1;
    if ([location respondsToSelector:@selector(speedAccuracy)]) {
        speedAccuracy = location.speedAccuracy;
    }

    BOOL weakFix = location.horizontalAccuracy > DDFairHorizontalAccuracy;
    BOOL speedUncertain = speedAccuracy < 0 || speedAccuracy > MAX(2.8, rawSpeed * 0.75);
    if (weakFix && rawSpeed < 8.0) {
        return 0;
    }
    if (rawSpeed < DDStationarySpeedThreshold && speedUncertain) {
        return 0;
    }
    if (rawSpeed < 1.35) {
        return 0;
    }
    if (self.lastGoodSpeed <= 0.01 && rawSpeed < 3.15 && location.horizontalAccuracy > DDGoodHorizontalAccuracy) {
        return 0;
    }

    if (self.lastGoodSpeed <= 0.01) {
        return rawSpeed;
    }

    double blend = rawSpeed > self.lastGoodSpeed ? 0.45 : 0.30;
    CLLocationSpeed smoothed = (self.lastGoodSpeed * (1.0 - blend)) + (rawSpeed * blend);
    if (smoothed < 1.35) {
        return 0;
    }
    return smoothed;
}

- (BOOL)shouldAccumulateDistanceForLocation:(CLLocation *)location previous:(CLLocation *)previous speed:(CLLocationSpeed)speed {
    if (!previous || speed <= 0.5) {
        return NO;
    }
    if (location.horizontalAccuracy < 0 || previous.horizontalAccuracy < 0) {
        return NO;
    }
    if (location.horizontalAccuracy > DDFairHorizontalAccuracy || previous.horizontalAccuracy > DDFairHorizontalAccuracy) {
        return NO;
    }

    NSTimeInterval elapsed = [location.timestamp timeIntervalSinceDate:previous.timestamp];
    if (elapsed <= 0 || elapsed > 15) {
        return NO;
    }

    CLLocationDistance distance = [location distanceFromLocation:previous];
    CLLocationDistance noiseFloor = MAX(4.0, MIN(20.0, (location.horizontalAccuracy + previous.horizontalAccuracy) * 0.18));
    return distance > noiseFloor && distance < 250;
}

- (CLLocationSpeed)speedFromLocationPair:(CLLocation *)previous current:(CLLocation *)current {
    if (!previous) {
        return 0;
    }

    NSTimeInterval elapsed = [current.timestamp timeIntervalSinceDate:previous.timestamp];
    if (elapsed <= 0 || elapsed > 15) {
        return 0;
    }
    if (current.horizontalAccuracy < 0 || previous.horizontalAccuracy < 0) {
        return 0;
    }
    if (current.horizontalAccuracy > DDFairHorizontalAccuracy || previous.horizontalAccuracy > DDFairHorizontalAccuracy) {
        return 0;
    }

    CLLocationDistance distance = [current distanceFromLocation:previous];
    CLLocationDistance noiseFloor = MAX(4.0, MIN(20.0, (current.horizontalAccuracy + previous.horizontalAccuracy) * 0.18));
    if (distance <= noiseFloor || distance > 250) {
        return 0;
    }
    return distance / elapsed;
}

@end

@implementation DDMetricView {
    UILabel *_titleLabel;
    UILabel *_valueLabel;
    UILabel *_subtitleLabel;
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor colorWithRed:0.085 green:0.100 blue:0.110 alpha:1.0];
        self.layer.cornerRadius = 7;
        self.clipsToBounds = YES;

        _titleLabel = [self metricLabelWithSize:10 weight:UIFontWeightBlack color:[UIColor colorWithWhite:0.56 alpha:1.0]];
        _titleLabel.text = title;
        _titleLabel.numberOfLines = 1;

        _valueLabel = [self metricLabelWithSize:18 weight:UIFontWeightBold color:[UIColor whiteColor]];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightBold];
        _valueLabel.minimumScaleFactor = 0.45;
        _valueLabel.numberOfLines = 1;

        _subtitleLabel = [self metricLabelWithSize:8 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.56 alpha:1.0]];
        _subtitleLabel.numberOfLines = 1;

        [self addSubview:_titleLabel];
        [self addSubview:_valueLabel];
        [self addSubview:_subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:7],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],

            [_valueLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:7],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
            [_valueLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:7],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:0],
            [_subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4]
        ]];

        [self updateValue:@"--" subtitle:@""];
    }
    return self;
}

- (UILabel *)metricLabelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.45;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)updateValue:(NSString *)value subtitle:(NSString *)subtitle {
    _valueLabel.text = value;
    _subtitleLabel.text = subtitle;
}

@end

@implementation DDGMeterView {
    double _lateralG;
    double _forwardG;
}

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor colorWithRed:0.085 green:0.100 blue:0.110 alpha:1.0];
        self.layer.cornerRadius = 7;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)updateLateral:(double)lateral forward:(double)forward {
    _lateralG = MAX(-1.25, MIN(1.25, lateral));
    _forwardG = MAX(-1.25, MIN(1.25, forward));
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) {
        return;
    }

    CGRect insetRect = CGRectInset(rect, 10, 24);
    CGPoint center = CGPointMake(CGRectGetMidX(insetRect), CGRectGetMidY(insetRect));
    CGFloat radius = MIN(CGRectGetWidth(insetRect), CGRectGetHeight(insetRect)) / 2.0;

    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:0.12].CGColor);
    CGContextSetLineWidth(context, 1);
    CGContextStrokeEllipseInRect(context, CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2));
    CGContextStrokeEllipseInRect(context, CGRectMake(center.x - radius * 0.5, center.y - radius * 0.5, radius, radius));
    CGContextMoveToPoint(context, center.x - radius, center.y);
    CGContextAddLineToPoint(context, center.x + radius, center.y);
    CGContextMoveToPoint(context, center.x, center.y - radius);
    CGContextAddLineToPoint(context, center.x, center.y + radius);
    CGContextStrokePath(context);

    CGFloat scale = radius / 1.25;
    CGPoint dot = CGPointMake(center.x + (CGFloat)_lateralG * scale, center.y - (CGFloat)_forwardG * scale);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.430 green:0.910 blue:0.640 alpha:1.0].CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(dot.x - 6, dot.y - 6, 12, 12));

    NSString *text = [NSString stringWithFormat:@"%.2fG", sqrt((_lateralG * _lateralG) + (_forwardG * _forwardG))];
    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    CGSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:CGPointMake(center.x - size.width / 2.0, 9) withAttributes:attributes];
}

@end
