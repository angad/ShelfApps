#import "CCCameraStoryViewController.h"
#import "CCImageLoader.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static NSTimeInterval const CCStoryImageHold = 6.0;
static NSTimeInterval const CCStoryLiveHold = 14.0;
static NSTimeInterval const CCStoryPrepareTimeout = 12.0;
static NSUInteger const CCStoryMaximumItems = 12;
static void *CCStoryPreparedItemStatusContext = &CCStoryPreparedItemStatusContext;

@interface CCStoryMediaView : UIView

@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) AVPlayer *player;
- (void)configureWithImage:(UIImage *)image;
- (void)configureWithPlayer:(AVPlayer *)player;
- (void)stop;

@end

@implementation CCStoryMediaView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.clipsToBounds = YES;
        self.imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds = YES;
        [self addSubview:self.imageView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}

- (void)configureWithImage:(UIImage *)image {
    [self stop];
    self.imageView.hidden = NO;
    self.imageView.image = image;
}

- (void)configureWithPlayer:(AVPlayer *)player {
    [self stop];
    self.player = player;
    self.imageView.hidden = YES;
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer insertSublayer:self.playerLayer atIndex:0];
}

- (void)stop {
    [self.player pause];
    [self.playerLayer removeFromSuperlayer];
    self.player = nil;
    self.playerLayer = nil;
}

@end

@interface CCCameraStoryViewController ()

@property (nonatomic, copy) NSArray<CCCamera *> *cameras;
@property (nonatomic, copy) NSString *accountTitle;
@property (nonatomic, copy) NSString *accountSubtitle;
@property (nonatomic, strong) UIView *mediaContainer;
@property (nonatomic, strong) CCStoryMediaView *currentMediaView;
@property (nonatomic, strong) CCStoryMediaView *preparedMediaView;
@property (nonatomic, strong) AVPlayerItem *preparedItem;
@property (nonatomic, strong) AVPlayer *preparedPlayer;
@property (nonatomic, strong) CCCamera *preparedCamera;
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *readyDot;
@property (nonatomic, strong) UIView *progressContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *progressFills;
@property (nonatomic, strong) NSTimer *advanceTimer;
@property (nonatomic, strong) NSTimer *prepareTimeoutTimer;
@property (nonatomic) NSInteger currentIndex;
@property (nonatomic) NSInteger preparedIndex;
@property (nonatomic) BOOL preparedReady;
@property (nonatomic) BOOL observingPreparedItem;
@property (nonatomic) BOOL preparedPrerolling;
@property (nonatomic) BOOL isTransitioning;
@property (nonatomic) BOOL shouldTransitionWhenPrepared;
@property (nonatomic) BOOL pendingTransitionForward;

@end

@implementation CCCameraStoryViewController

- (instancetype)initWithCameras:(NSArray<CCCamera *> *)cameras accountTitle:(NSString *)accountTitle accountSubtitle:(NSString *)accountSubtitle {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _cameras = [self shuffledStoryCameras:cameras ?: @[]];
        _accountTitle = [accountTitle copy] ?: @"Cameras";
        _accountSubtitle = [accountSubtitle copy] ?: @"";
        _currentIndex = -1;
        _preparedIndex = -1;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self buildInterface];
    if (self.cameras.count == 0) {
        self.accountLabel.text = @"No story available";
        self.detailLabel.text = @"";
    } else {
        [self prepareCameraAtIndex:0];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.mediaContainer.frame = self.view.bounds;
    self.currentMediaView.frame = self.mediaContainer.bounds;
    self.preparedMediaView.frame = self.mediaContainer.bounds;
    CGFloat width = self.view.bounds.size.width;
    CGFloat top = 24.0;
    self.progressContainer.frame = CGRectMake(10, top, width - 20, 4);
    [self layoutProgressSegments];
    self.closeButton.frame = CGRectMake(width - 54, 36, 42, 34);
    self.readyDot.frame = CGRectMake(width - 26, 78, 8, 8);
    self.readyDot.layer.cornerRadius = 4.0;
    self.accountLabel.frame = CGRectMake(16, 38, width - 78, 22);
    self.detailLabel.frame = CGRectMake(16, 60, width - 78, 18);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self stopPlaybackAndTimers];
}

- (void)dealloc {
    [self stopPlaybackAndTimers];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (NSArray<CCCamera *> *)shuffledStoryCameras:(NSArray<CCCamera *> *)cameras {
    NSMutableArray *live = [NSMutableArray array];
    NSMutableArray *images = [NSMutableArray array];
    for (CCCamera *camera in cameras) {
        if ([camera hasPlayableStream]) {
            [live addObject:camera];
        } else if (camera.imageURL.length) {
            [images addObject:camera];
        }
    }
    NSArray *shuffledLive = [self shuffledArray:live];
    NSArray *shuffledImages = [self shuffledArray:images];
    NSMutableArray *combined = [NSMutableArray array];
    [combined addObjectsFromArray:shuffledLive];
    [combined addObjectsFromArray:shuffledImages];
    if (combined.count > CCStoryMaximumItems) {
        return [combined subarrayWithRange:NSMakeRange(0, CCStoryMaximumItems)];
    }
    return combined;
}

- (NSArray *)shuffledArray:(NSArray *)array {
    NSMutableArray *items = [array mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = items.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [items exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
    return items;
}

- (void)buildInterface {
    self.mediaContainer = [[UIView alloc] initWithFrame:self.view.bounds];
    self.mediaContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mediaContainer.backgroundColor = [UIColor blackColor];
    [self.view addSubview:self.mediaContainer];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mediaTapped:)];
    [self.mediaContainer addGestureRecognizer:tap];

    self.progressContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.progressContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.progressContainer];
    [self buildProgressSegments];

    self.accountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.accountLabel.textColor = [UIColor whiteColor];
    self.accountLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBlack];
    self.accountLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.86];
    self.accountLabel.shadowOffset = CGSizeMake(0, 1);
    self.accountLabel.text = self.accountTitle;
    [self.view addSubview:self.accountLabel];

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.detailLabel.textColor = [UIColor colorWithWhite:0.94 alpha:0.90];
    self.detailLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.detailLabel.adjustsFontSizeToFitWidth = YES;
    self.detailLabel.minimumScaleFactor = 0.72;
    self.detailLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    self.detailLabel.shadowOffset = CGSizeMake(0, 1);
    self.detailLabel.text = self.accountSubtitle;
    [self.view addSubview:self.detailLabel];

    self.readyDot = [[UIView alloc] initWithFrame:CGRectZero];
    self.readyDot.backgroundColor = [UIColor colorWithRed:0.28 green:0.92 blue:0.50 alpha:1.0];
    self.readyDot.alpha = 0.0;
    [self.view addSubview:self.readyDot];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"X" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack];
    self.closeButton.titleLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    self.closeButton.titleLabel.shadowOffset = CGSizeMake(0, 1);
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];
}

- (void)buildProgressSegments {
    [self.progressContainer.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.progressFills = [NSMutableArray array];
    NSUInteger count = MAX((NSUInteger)1, self.cameras.count);
    for (NSUInteger i = 0; i < count; i++) {
        UIView *track = [[UIView alloc] initWithFrame:CGRectZero];
        track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
        track.layer.cornerRadius = 1.5;
        track.layer.masksToBounds = YES;
        [self.progressContainer addSubview:track];

        UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
        fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.94];
        [track addSubview:fill];
        [self.progressFills addObject:fill];
    }
}

- (void)layoutProgressSegments {
    NSUInteger count = self.progressContainer.subviews.count;
    if (count == 0) return;
    CGFloat gap = 3.0;
    CGFloat totalGap = gap * (count - 1);
    CGFloat width = floor((self.progressContainer.bounds.size.width - totalGap) / count);
    CGFloat x = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        UIView *track = self.progressContainer.subviews[i];
        track.frame = CGRectMake(x, 0, width, 3);
        track.layer.cornerRadius = 1.5;
        UIView *fill = self.progressFills[i];
        [fill.layer removeAllAnimations];
        CGFloat fillRatio = 0.0;
        if ((NSInteger)i < self.currentIndex) fillRatio = 1.0;
        fill.frame = CGRectMake(0, 0, width * fillRatio, 3);
        x += width + gap;
    }
}

- (void)prepareCameraAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.cameras.count || self.preparedMediaView || self.isTransitioning) return;
    CCCamera *camera = self.cameras[index];
    self.preparedIndex = index;
    self.preparedCamera = camera;
    self.preparedReady = NO;
    [self setReadyDotVisible:NO];

    CCStoryMediaView *mediaView = [[CCStoryMediaView alloc] initWithFrame:self.mediaContainer.bounds];
    mediaView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mediaView.hidden = YES;
    self.preparedMediaView = mediaView;
    [self.mediaContainer addSubview:mediaView];

    if ([camera hasPlayableStream]) {
        [self prepareLiveCamera:camera];
    } else {
        [self prepareImageCamera:camera];
    }
}

- (void)prepareImageCamera:(CCCamera *)camera {
    [self startPrepareTimeout];
    NSString *imageURL = camera.imageURL;
    __weak typeof(self) weakSelf = self;
    [[CCImageLoader sharedLoader] loadImageAtURL:imageURL completion:^(UIImage *image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || camera != strongSelf.preparedCamera || !strongSelf.preparedMediaView) return;
        if (!image) {
            [strongSelf preparedMediaFailed];
            return;
        }
        [strongSelf.preparedMediaView configureWithImage:image];
        [strongSelf preparedMediaBecameReady];
    }];
}

- (void)prepareLiveCamera:(CCCamera *)camera {
    NSURL *url = [NSURL URLWithString:camera.streamURL];
    if (!url) {
        [self preparedMediaFailed];
        return;
    }
    [self startPrepareTimeout];
    self.preparedItem = [AVPlayerItem playerItemWithURL:url];
    [self.preparedItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:CCStoryPreparedItemStatusContext];
    self.observingPreparedItem = YES;
    self.preparedPlayer = [AVPlayer playerWithPlayerItem:self.preparedItem];
    self.preparedPlayer.muted = YES;
    [self.preparedMediaView configureWithPlayer:self.preparedPlayer];
}

- (void)startPrepareTimeout {
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:CCStoryPrepareTimeout target:self selector:@selector(preparedItemTimedOut) userInfo:nil repeats:NO];
}

- (void)preparedItemTimedOut {
    [self preparedMediaFailed];
}

- (void)preparedMediaFailed {
    BOOL continuePendingTransition = self.shouldTransitionWhenPrepared;
    BOOL pendingForward = self.pendingTransitionForward;
    NSInteger failedIndex = self.preparedIndex;
    [self discardPreparedMedia];
    NSInteger nextIndex = failedIndex + 1;
    if (nextIndex < (NSInteger)self.cameras.count) {
        self.shouldTransitionWhenPrepared = continuePendingTransition;
        self.pendingTransitionForward = pendingForward;
        [self prepareCameraAtIndex:nextIndex];
    } else if (self.currentIndex < 0) {
        self.accountLabel.text = @"No story available";
        self.detailLabel.text = @"";
    } else {
        [self scheduleAdvanceTimerForCurrentCamera];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != CCStoryPreparedItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != self.preparedItem) return;
        if (self.preparedItem.status == AVPlayerItemStatusReadyToPlay) {
            [self prerollPreparedPlayer];
        } else if (self.preparedItem.status == AVPlayerItemStatusFailed) {
            [self preparedMediaFailed];
        }
    });
}

- (void)prerollPreparedPlayer {
    if (self.preparedPrerolling || self.preparedReady || !self.preparedPlayer || !self.preparedItem) return;
    self.preparedPrerolling = YES;
    AVPlayer *player = self.preparedPlayer;
    AVPlayerItem *item = self.preparedItem;
    __weak typeof(self) weakSelf = self;
    [player prerollAtRate:1.0 completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || player != strongSelf.preparedPlayer || item != strongSelf.preparedItem) return;
            strongSelf.preparedPrerolling = NO;
            if (!finished || item.status != AVPlayerItemStatusReadyToPlay) {
                [strongSelf preparedMediaFailed];
                return;
            }
            [strongSelf preparedMediaBecameReady];
        });
    }];
}

- (void)preparedMediaBecameReady {
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = nil;
    self.preparedReady = YES;
    [self setReadyDotVisible:self.currentMediaView != nil];
    if (self.shouldTransitionWhenPrepared) {
        BOOL forward = self.pendingTransitionForward;
        self.shouldTransitionWhenPrepared = NO;
        [self transitionToPreparedMediaForward:forward animated:YES];
        return;
    }
    if (!self.currentMediaView) {
        [self transitionToPreparedMediaForward:YES animated:NO];
    }
}

- (void)transitionToPreparedMediaForward:(BOOL)forward animated:(BOOL)animated {
    if (!self.preparedReady || !self.preparedMediaView || self.isTransitioning) return;
    self.isTransitioning = YES;
    [self.advanceTimer invalidate];
    self.advanceTimer = nil;

    CCStoryMediaView *oldView = self.currentMediaView;
    CCStoryMediaView *newView = self.preparedMediaView;
    CCCamera *camera = self.preparedCamera;
    NSInteger newIndex = self.preparedIndex;

    self.currentMediaView = newView;
    self.currentIndex = newIndex;
    self.preparedMediaView = nil;
    self.preparedCamera = nil;
    self.preparedReady = NO;
    self.preparedIndex = -1;
    self.shouldTransitionWhenPrepared = NO;
    [self clearPreparedItemObserver];
    self.preparedItem = nil;
    self.preparedPlayer = nil;
    [self setReadyDotVisible:NO];
    [self updateOverlayForCamera:camera];

    newView.hidden = NO;
    [newView.player play];
    if (!animated || !oldView) {
        [oldView stop];
        [oldView removeFromSuperview];
        self.isTransitioning = NO;
        [self startProgressForCurrentCamera];
        [self prepareCameraAtIndex:self.currentIndex + 1];
        return;
    }

    [self.mediaContainer bringSubviewToFront:newView];
    [self performCubeTransitionFromView:oldView toView:newView forward:forward completion:^{
        [oldView stop];
        [oldView removeFromSuperview];
        self.isTransitioning = NO;
        [self startProgressForCurrentCamera];
        [self prepareCameraAtIndex:self.currentIndex + 1];
    }];
}

- (void)performCubeTransitionFromView:(UIView *)oldView toView:(UIView *)newView forward:(BOOL)forward completion:(void (^)(void))completion {
    CGFloat width = self.mediaContainer.bounds.size.width;
    CGFloat direction = forward ? 1.0 : -1.0;
    CATransform3D perspective = CATransform3DIdentity;
    perspective.m34 = -1.0 / 700.0;
    self.mediaContainer.layer.sublayerTransform = perspective;

    oldView.layer.anchorPoint = CGPointMake(forward ? 0.0 : 1.0, 0.5);
    newView.layer.anchorPoint = CGPointMake(forward ? 1.0 : 0.0, 0.5);
    oldView.center = CGPointMake(forward ? 0.0 : width, self.mediaContainer.bounds.size.height / 2.0);
    newView.center = CGPointMake(forward ? width : 0.0, self.mediaContainer.bounds.size.height / 2.0);
    newView.layer.transform = CATransform3DMakeRotation(-direction * M_PI_2, 0, 1, 0);
    oldView.layer.transform = CATransform3DIdentity;

    [UIView animateWithDuration:0.42 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        oldView.layer.transform = CATransform3DMakeRotation(direction * M_PI_2, 0, 1, 0);
        newView.layer.transform = CATransform3DIdentity;
    } completion:^(BOOL finished) {
        self.mediaContainer.layer.sublayerTransform = CATransform3DIdentity;
        oldView.layer.anchorPoint = CGPointMake(0.5, 0.5);
        newView.layer.anchorPoint = CGPointMake(0.5, 0.5);
        oldView.layer.transform = CATransform3DIdentity;
        newView.layer.transform = CATransform3DIdentity;
        newView.frame = self.mediaContainer.bounds;
        oldView.frame = self.mediaContainer.bounds;
        if (completion) completion();
    }];
}

- (void)startProgressForCurrentCamera {
    [self layoutProgressSegments];
    if (self.currentIndex >= 0 && self.currentIndex < (NSInteger)self.progressFills.count) {
        UIView *fill = self.progressFills[(NSUInteger)self.currentIndex];
        UIView *track = fill.superview;
        fill.frame = CGRectMake(0, 0, 0, track.bounds.size.height);
        NSTimeInterval hold = [self holdDurationForCamera:self.cameras[(NSUInteger)self.currentIndex]];
        [UIView animateWithDuration:hold delay:0 options:UIViewAnimationOptionCurveLinear animations:^{
            fill.frame = CGRectMake(0, 0, track.bounds.size.width, track.bounds.size.height);
        } completion:nil];
    }
    [self scheduleAdvanceTimerForCurrentCamera];
}

- (void)scheduleAdvanceTimerForCurrentCamera {
    [self.advanceTimer invalidate];
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)self.cameras.count) return;
    NSTimeInterval hold = [self holdDurationForCamera:self.cameras[(NSUInteger)self.currentIndex]];
    self.advanceTimer = [NSTimer scheduledTimerWithTimeInterval:hold target:self selector:@selector(advanceTimerFired) userInfo:nil repeats:NO];
}

- (NSTimeInterval)holdDurationForCamera:(CCCamera *)camera {
    return [camera hasPlayableStream] ? CCStoryLiveHold : CCStoryImageHold;
}

- (void)advanceTimerFired {
    [self showNextStory];
}

- (void)showNextStory {
    if (self.isTransitioning) return;
    if (self.preparedReady) {
        [self transitionToPreparedMediaForward:YES animated:YES];
        return;
    }
    NSInteger nextIndex = self.currentIndex + 1;
    if (nextIndex >= (NSInteger)self.cameras.count) {
        [self closeTapped];
        return;
    }
    [self.advanceTimer invalidate];
    self.advanceTimer = nil;
    self.shouldTransitionWhenPrepared = YES;
    self.pendingTransitionForward = YES;
    if (self.preparedMediaView && self.preparedIndex == nextIndex) {
        return;
    }
    [self discardPreparedMedia];
    self.shouldTransitionWhenPrepared = YES;
    self.pendingTransitionForward = YES;
    [self prepareCameraAtIndex:nextIndex];
}

- (void)showPreviousStory {
    if (self.isTransitioning || self.currentIndex <= 0) return;
    [self discardPreparedMedia];
    [self.advanceTimer invalidate];
    self.advanceTimer = nil;
    NSInteger previousIndex = self.currentIndex - 1;
    self.shouldTransitionWhenPrepared = YES;
    self.pendingTransitionForward = NO;
    [self prepareCameraAtIndex:previousIndex];
}

- (void)mediaTapped:(UITapGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self.mediaContainer];
    if (point.x < self.mediaContainer.bounds.size.width * 0.33) {
        [self showPreviousStory];
    } else {
        [self showNextStory];
    }
}

- (void)updateOverlayForCamera:(CCCamera *)camera {
    NSMutableArray *details = [NSMutableArray array];
    if (camera.city.length) [details addObject:camera.city];
    if (camera.title.length) [details addObject:camera.title];
    if (details.count == 0 && self.accountSubtitle.length) [details addObject:self.accountSubtitle];
    NSString *detail = details.count ? [details componentsJoinedByString:@" : "] : @"";
    [UIView transitionWithView:self.detailLabel duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.detailLabel.text = detail;
    } completion:nil];
}

- (void)setReadyDotVisible:(BOOL)visible {
    [UIView animateWithDuration:0.16 animations:^{
        self.readyDot.alpha = visible ? 1.0 : 0.0;
    }];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)discardPreparedMedia {
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = nil;
    [self.preparedPlayer pause];
    [self.preparedMediaView stop];
    [self.preparedMediaView removeFromSuperview];
    [self clearPreparedItemObserver];
    self.preparedItem = nil;
    self.preparedPlayer = nil;
    self.preparedMediaView = nil;
    self.preparedCamera = nil;
    self.preparedReady = NO;
    self.preparedPrerolling = NO;
    self.preparedIndex = -1;
    self.shouldTransitionWhenPrepared = NO;
    [self setReadyDotVisible:NO];
}

- (void)clearPreparedItemObserver {
    if (self.observingPreparedItem && self.preparedItem) {
        [self.preparedItem removeObserver:self forKeyPath:@"status" context:CCStoryPreparedItemStatusContext];
    }
    self.observingPreparedItem = NO;
}

- (void)stopPlaybackAndTimers {
    [self.advanceTimer invalidate];
    self.advanceTimer = nil;
    [self.prepareTimeoutTimer invalidate];
    self.prepareTimeoutTimer = nil;
    [self.currentMediaView stop];
    [self.preparedMediaView stop];
    [self.currentMediaView removeFromSuperview];
    [self.preparedMediaView removeFromSuperview];
    [self clearPreparedItemObserver];
    self.currentMediaView = nil;
    self.preparedMediaView = nil;
    self.preparedItem = nil;
    self.preparedPlayer = nil;
    self.preparedReady = NO;
    self.preparedPrerolling = NO;
    self.shouldTransitionWhenPrepared = NO;
}

@end
