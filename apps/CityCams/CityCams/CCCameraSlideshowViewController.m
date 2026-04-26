#import "CCCameraSlideshowViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static NSTimeInterval const CCSlideshowMinimumHold = 24.0;
static NSTimeInterval const CCSlideshowPrepareTimeout = 14.0;
static void *CCSlideshowPlayerItemStatusContext = &CCSlideshowPlayerItemStatusContext;

@interface CCCameraSlideshowViewController ()

@property (nonatomic, copy) NSArray<CCCamera *> *liveCameras;
@property (nonatomic, strong) AVPlayer *currentPlayer;
@property (nonatomic, strong) AVPlayerLayer *currentLayer;
@property (nonatomic, strong) AVPlayer *preparedPlayer;
@property (nonatomic, strong) AVPlayerLayer *preparedLayer;
@property (nonatomic, strong) AVPlayerItem *preparedItem;
@property (nonatomic, strong) CCCamera *currentCamera;
@property (nonatomic, strong) CCCamera *preparedCamera;
@property (nonatomic, strong) UIView *readyDot;
@property (nonatomic, strong) UILabel *locationLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) NSTimer *advanceTimer;
@property (nonatomic, strong) NSTimer *prepareTimeoutTimer;
@property (nonatomic) BOOL preparedReady;
@property (nonatomic) BOOL observingPreparedItem;
@property (nonatomic) BOOL isTransitioning;
@property (nonatomic) BOOL preparedPrerolling;

@end

@implementation CCCameraSlideshowViewController

- (instancetype)initWithCameras:(NSArray<CCCamera *> *)cameras {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(CCCamera *camera, NSDictionary *bindings) {
            return [camera hasPlayableStream];
        }];
        _liveCameras = [cameras filteredArrayUsingPredicate:predicate];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self buildInterface];
    [self prepareNextCameraExcluding:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.currentLayer.frame = self.view.bounds;
    self.preparedLayer.frame = self.view.bounds;
    CGFloat width = self.view.bounds.size.width;
    CGFloat bottom = self.view.bounds.size.height;
    self.locationLabel.frame = CGRectMake(16, bottom - 70, width - 32, 28);
    self.detailLabel.frame = CGRectMake(16, bottom - 42, width - 32, 24);
    self.readyDot.frame = CGRectMake(width - 26, 26, 10, 10);
    self.readyDot.layer.cornerRadius = 5.0;
    self.closeButton.frame = CGRectMake(14, 22, 76, 36);
    self.nextButton.frame = CGRectMake(width - 90, 22, 76, 36);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPlaybackAndTimers];
}

- (void)dealloc {
    [self stopPlaybackAndTimers];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)buildInterface {
    self.closeButton = [self translucentButtonWithTitle:@"Close"];
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    self.nextButton = [self translucentButtonWithTitle:@"Next"];
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.nextButton];

    self.readyDot = [[UIView alloc] initWithFrame:CGRectZero];
    self.readyDot.backgroundColor = [UIColor colorWithRed:0.28 green:0.92 blue:0.50 alpha:1.0];
    self.readyDot.layer.shadowColor = [UIColor blackColor].CGColor;
    self.readyDot.layer.shadowOpacity = 0.55;
    self.readyDot.layer.shadowRadius = 3.0;
    self.readyDot.layer.shadowOffset = CGSizeMake(0, 1);
    self.readyDot.alpha = 0.0;
    [self.view addSubview:self.readyDot];

    self.locationLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 10, 34)];
    self.locationLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.locationLabel.textColor = [UIColor whiteColor];
    self.locationLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBlack];
    self.locationLabel.adjustsFontSizeToFitWidth = YES;
    self.locationLabel.minimumScaleFactor = 0.72;
    self.locationLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.86];
    self.locationLabel.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:self.locationLabel];

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 48, 10, 40)];
    self.detailLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.detailLabel.textColor = [UIColor colorWithWhite:0.92 alpha:0.86];
    self.detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.detailLabel.numberOfLines = 1;
    self.detailLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    self.detailLabel.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:self.detailLabel];

    self.locationLabel.text = self.liveCameras.count ? @"Preparing live camera" : @"No live HLS streams";
    self.detailLabel.text = @"";
}

- (UIButton *)translucentButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [UIColor clearColor];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBlack];
    button.titleLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    button.titleLabel.shadowOffset = CGSizeMake(0, 1);
    return button;
}

- (void)prepareNextCameraExcluding:(CCCamera *)excludedCamera {
    if (self.liveCameras.count == 0 || self.preparedItem || self.isTransitioning) return;
    CCCamera *camera = [self randomCameraExcluding:excludedCamera];
    NSURL *url = [NSURL URLWithString:camera.streamURL];
    if (!url) {
        [self retryAfterDelayExcluding:camera];
        return;
    }

    self.preparedReady = NO;
    self.preparedCamera = camera;
    self.preparedItem = [AVPlayerItem playerItemWithURL:url];
    [self.preparedItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:CCSlideshowPlayerItemStatusContext];
    self.observingPreparedItem = YES;
    self.preparedPlayer = [AVPlayer playerWithPlayerItem:self.preparedItem];
    self.preparedPlayer.muted = YES;
    self.preparedLayer = [AVPlayerLayer playerLayerWithPlayer:self.preparedPlayer];
    self.preparedLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.preparedLayer.frame = self.view.bounds;
    self.preparedLayer.opacity = 0.0;
    if (self.currentLayer) {
        [self.view.layer insertSublayer:self.preparedLayer above:self.currentLayer];
    } else {
        [self.view.layer insertSublayer:self.preparedLayer atIndex:0];
    }
    [self setReadyDotVisible:NO];
    [self startPrepareTimeout];
}

- (CCCamera *)randomCameraExcluding:(CCCamera *)excludedCamera {
    if (self.liveCameras.count == 1) return self.liveCameras.firstObject;
    CCCamera *camera = nil;
    for (NSUInteger attempt = 0; attempt < 8; attempt++) {
        NSUInteger index = arc4random_uniform((uint32_t)self.liveCameras.count);
        camera = self.liveCameras[index];
        if (![camera.identifier isEqualToString:excludedCamera.identifier]) return camera;
    }
    return camera ?: self.liveCameras.firstObject;
}

- (void)startPrepareTimeout {
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:CCSlideshowPrepareTimeout target:self selector:@selector(preparedItemTimedOut) userInfo:nil repeats:NO];
}

- (void)preparedItemTimedOut {
    CCCamera *failedCamera = self.preparedCamera;
    [self discardPreparedPlayer];
    [self retryAfterDelayExcluding:failedCamera];
}

- (void)retryAfterDelayExcluding:(CCCamera *)camera {
    [self setReadyDotVisible:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self prepareNextCameraExcluding:camera];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != CCSlideshowPlayerItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != self.preparedItem) return;
        if (self.preparedItem.status == AVPlayerItemStatusReadyToPlay) {
            [self prerollPreparedPlayer];
        } else if (self.preparedItem.status == AVPlayerItemStatusFailed) {
            CCCamera *failedCamera = self.preparedCamera;
            [self discardPreparedPlayer];
            [self retryAfterDelayExcluding:failedCamera];
        }
    });
}

- (void)prerollPreparedPlayer {
    if (self.preparedReady || self.preparedPrerolling || !self.preparedPlayer || !self.preparedItem) return;
    self.preparedPrerolling = YES;
    [self setReadyDotVisible:NO];
    AVPlayer *player = self.preparedPlayer;
    AVPlayerItem *item = self.preparedItem;
    CCCamera *camera = self.preparedCamera;
    __weak typeof(self) weakSelf = self;
    [player prerollAtRate:1.0 completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || player != strongSelf.preparedPlayer || item != strongSelf.preparedItem) return;
            strongSelf.preparedPrerolling = NO;
            if (!finished || item.status != AVPlayerItemStatusReadyToPlay) {
                [strongSelf discardPreparedPlayer];
                [strongSelf retryAfterDelayExcluding:camera];
                return;
            }
            [strongSelf.prepareTimeoutTimer invalidate];
            strongSelf.prepareTimeoutTimer = nil;
            strongSelf.preparedReady = YES;
            [strongSelf setReadyDotVisible:strongSelf.currentPlayer != nil];
            if (!strongSelf.currentPlayer) {
                [strongSelf transitionToPreparedCamera];
            }
        });
    }];
}

- (void)transitionToPreparedCamera {
    if (!self.preparedReady || !self.preparedPlayer || self.isTransitioning) return;
    self.isTransitioning = YES;
    AVPlayer *oldPlayer = self.currentPlayer;
    AVPlayerLayer *oldLayer = self.currentLayer;
    CCCamera *camera = self.preparedCamera;

    self.currentPlayer = self.preparedPlayer;
    self.currentLayer = self.preparedLayer;
    self.currentCamera = camera;
    self.preparedPlayer = nil;
    self.preparedLayer = nil;
    [self clearPreparedItemObserver];
    self.preparedItem = nil;
    self.preparedCamera = nil;
    self.preparedReady = NO;
    [self setReadyDotVisible:NO];

    self.currentLayer.opacity = 0.0;
    [self.currentPlayer play];
    [self updateOverlayForCamera:camera];
    [UIView animateWithDuration:0.75 animations:^{
        self.currentLayer.opacity = 1.0;
    } completion:^(BOOL finished) {
        [oldPlayer pause];
        [oldLayer removeFromSuperlayer];
        self.isTransitioning = NO;
        [self scheduleAdvanceTimer];
        [self prepareNextCameraExcluding:self.currentCamera];
    }];
}

- (void)scheduleAdvanceTimer {
    [self.advanceTimer invalidate];
    self.advanceTimer = [NSTimer scheduledTimerWithTimeInterval:CCSlideshowMinimumHold target:self selector:@selector(advanceTimerFired) userInfo:nil repeats:NO];
}

- (void)advanceTimerFired {
    if (self.preparedReady) {
        [self transitionToPreparedCamera];
    } else {
        [self setReadyDotVisible:NO];
        [self scheduleAdvanceTimer];
        [self prepareNextCameraExcluding:self.currentCamera];
    }
}

- (void)nextTapped {
    [self.advanceTimer invalidate];
    if (self.preparedReady) {
        [self transitionToPreparedCamera];
    } else {
        [self setReadyDotVisible:NO];
        [self discardPreparedPlayer];
        [self prepareNextCameraExcluding:self.currentCamera];
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateOverlayForCamera:(CCCamera *)camera {
    NSString *location = [self locationLineForCamera:camera];
    NSString *detail = [self detailLineForCamera:camera];
    [UIView transitionWithView:self.locationLabel duration:0.35 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.locationLabel.text = location;
    } completion:nil];
    [UIView transitionWithView:self.detailLabel duration:0.35 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.detailLabel.text = detail;
    } completion:nil];
}

- (void)setReadyDotVisible:(BOOL)visible {
    CGFloat alpha = visible ? 1.0 : 0.0;
    [UIView animateWithDuration:0.2 animations:^{
        self.readyDot.alpha = alpha;
    }];
}

- (NSString *)locationLineForCamera:(CCCamera *)camera {
    NSMutableArray *parts = [NSMutableArray array];
    if (camera.stateName.length) [parts addObject:camera.stateName];
    if (camera.city.length && ![camera.city isEqualToString:camera.stateName]) [parts addObject:camera.city];
    if (camera.title.length) [parts addObject:camera.title];
    return parts.count ? [parts componentsJoinedByString:@" : "] : @"Live camera";
}

- (NSString *)detailLineForCamera:(CCCamera *)camera {
    NSMutableArray *parts = [NSMutableArray array];
    if (camera.sourceName.length) [parts addObject:camera.sourceName];
    if (camera.subtitle.length) [parts addObject:camera.subtitle];
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"";
}

- (void)discardPreparedPlayer {
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = nil;
    [self.preparedPlayer pause];
    [self.preparedLayer removeFromSuperlayer];
    [self clearPreparedItemObserver];
    self.preparedItem = nil;
    self.preparedPlayer = nil;
    self.preparedLayer = nil;
    self.preparedCamera = nil;
    self.preparedReady = NO;
    self.preparedPrerolling = NO;
    [self setReadyDotVisible:NO];
}

- (void)clearPreparedItemObserver {
    if (self.observingPreparedItem && self.preparedItem) {
        [self.preparedItem removeObserver:self forKeyPath:@"status" context:CCSlideshowPlayerItemStatusContext];
    }
    self.observingPreparedItem = NO;
}

- (void)stopPlaybackAndTimers {
    [self.advanceTimer invalidate];
    self.advanceTimer = nil;
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = nil;
    [self.currentPlayer pause];
    [self.preparedPlayer pause];
    [self.currentLayer removeFromSuperlayer];
    [self.preparedLayer removeFromSuperlayer];
    [self clearPreparedItemObserver];
    self.currentPlayer = nil;
    self.currentLayer = nil;
    self.preparedPlayer = nil;
    self.preparedLayer = nil;
    self.preparedItem = nil;
    self.preparedReady = NO;
    self.preparedPrerolling = NO;
    [self setReadyDotVisible:NO];
}

@end
