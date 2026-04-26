#import "CCCameraDetailViewController.h"
#import "CCImageLoader.h"
#import <AVKit/AVKit.h>

static UIColor *CCDetailBackgroundColor(void) {
    return [UIColor colorWithRed:0.035 green:0.075 blue:0.095 alpha:1.0];
}

static UIColor *CCDetailPanelColor(void) {
    return [UIColor colorWithRed:0.075 green:0.135 blue:0.155 alpha:1.0];
}

@interface CCCameraDetailViewController ()

@property (nonatomic, strong) CCCamera *camera;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *metadataLabel;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) AVPlayerViewController *playerController;

@end

@implementation CCCameraDetailViewController

- (instancetype)initWithCamera:(CCCamera *)camera {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.camera = camera;
        self.title = camera.city.length ? camera.city : camera.title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = CCDetailBackgroundColor();
    [self buildInterface];
    if ([self.camera hasPlayableStream]) {
        [self startVideo];
    } else {
        [self loadStillImageRefreshing:NO];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.playerController.player pause];
}

- (void)buildInterface {
    CGFloat width = self.view.bounds.size.width;
    CGFloat mediaHeight = MAX(220.0, MIN(330.0, self.view.bounds.size.height * 0.45));

    UIView *mediaPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, mediaHeight)];
    mediaPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    mediaPanel.backgroundColor = [UIColor blackColor];
    [self.view addSubview:mediaPanel];

    self.imageView = [[UIImageView alloc] initWithFrame:mediaPanel.bounds];
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.backgroundColor = [UIColor blackColor];
    [mediaPanel addSubview:self.imageView];

    UIView *infoPanel = [[UIView alloc] initWithFrame:CGRectMake(0, mediaHeight, width, self.view.bounds.size.height - mediaHeight)];
    infoPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    infoPanel.backgroundColor = CCDetailPanelColor();
    [self.view addSubview:infoPanel];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, width - 32, 54)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLabel.text = self.camera.title.length ? self.camera.title : @"Camera";
    titleLabel.textColor = [UIColor colorWithWhite:0.98 alpha:1.0];
    titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBlack];
    titleLabel.numberOfLines = 2;
    [infoPanel addSubview:titleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 75, width - 32, 26)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = [UIColor colorWithRed:0.39 green:0.92 blue:0.84 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBlack];
    self.statusLabel.text = [self.camera feedTypeLabel];
    [infoPanel addSubview:self.statusLabel];

    self.metadataLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 110, width - 32, infoPanel.bounds.size.height - 126)];
    self.metadataLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.metadataLabel.textColor = [UIColor colorWithRed:0.75 green:0.87 blue:0.88 alpha:1.0];
    self.metadataLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.metadataLabel.numberOfLines = 0;
    self.metadataLabel.text = [self metadataText];
    [infoPanel addSubview:self.metadataLabel];

    self.refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.refreshButton.frame = CGRectMake(width - 122, 72, 106, 32);
    self.refreshButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.refreshButton setTitle:@"Refresh" forState:UIControlStateNormal];
    [self.refreshButton setTitleColor:[UIColor colorWithRed:0.03 green:0.08 blue:0.09 alpha:1.0] forState:UIControlStateNormal];
    self.refreshButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBlack];
    self.refreshButton.backgroundColor = [UIColor colorWithRed:0.39 green:0.92 blue:0.84 alpha:1.0];
    self.refreshButton.layer.cornerRadius = 5.0;
    [self.refreshButton addTarget:self action:@selector(refreshButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.refreshButton.hidden = self.camera.feedType == CCCameraFeedTypeHLS;
    [infoPanel addSubview:self.refreshButton];
}

- (void)startVideo {
    NSURL *url = [NSURL URLWithString:self.camera.streamURL];
    if (!url) {
        self.statusLabel.text = @"Invalid stream URL";
        [self loadStillImageRefreshing:NO];
        return;
    }
    self.statusLabel.text = @"Opening live HLS stream...";
    AVPlayer *player = [AVPlayer playerWithURL:url];
    self.playerController = [[AVPlayerViewController alloc] init];
    self.playerController.player = player;
    self.playerController.view.frame = self.imageView.superview.bounds;
    self.playerController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addChildViewController:self.playerController];
    [self.imageView.superview addSubview:self.playerController.view];
    [self.playerController didMoveToParentViewController:self];
    [player play];
    self.statusLabel.text = @"Live HLS stream";
}

- (void)loadStillImageRefreshing:(BOOL)refreshing {
    if (self.camera.imageURL.length == 0) {
        self.statusLabel.text = @"No direct image feed. Use source URL.";
        return;
    }
    self.statusLabel.text = refreshing ? @"Refreshing camera image..." : @"Loading camera image...";
    void (^completion)(UIImage *) = ^(UIImage *image) {
        if (image) {
            self.imageView.image = image;
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterMediumStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
            self.statusLabel.text = [NSString stringWithFormat:@"Image refreshed %@", [formatter stringFromDate:[NSDate date]]];
        } else {
            self.statusLabel.text = @"Image feed unavailable";
        }
    };
    if (refreshing) {
        [[CCImageLoader sharedLoader] refreshImageAtURL:self.camera.imageURL completion:completion];
    } else {
        [[CCImageLoader sharedLoader] loadImageAtURL:self.camera.imageURL completion:completion];
    }
    if (!self.refreshTimer) {
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:45.0 target:self selector:@selector(refreshButtonTapped) userInfo:nil repeats:YES];
    }
}

- (void)refreshButtonTapped {
    [self loadStillImageRefreshing:YES];
}

- (NSString *)metadataText {
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"State: %@", self.camera.stateName ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"City/region: %@", self.camera.city ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"Source: %@", self.camera.sourceName ?: @""]];
    if (self.camera.subtitle.length) [lines addObject:[NSString stringWithFormat:@"Route/context: %@", self.camera.subtitle]];
    if (self.camera.updatedText.length) [lines addObject:[NSString stringWithFormat:@"Source timestamp: %@", self.camera.updatedText]];
    if (self.camera.latitude != 0 || self.camera.longitude != 0) {
        [lines addObject:[NSString stringWithFormat:@"Location: %.5f, %.5f", self.camera.latitude, self.camera.longitude]];
    }
    if (self.camera.streamURL.length) [lines addObject:[NSString stringWithFormat:@"Stream: %@", self.camera.streamURL]];
    if (self.camera.imageURL.length) [lines addObject:[NSString stringWithFormat:@"Image: %@", self.camera.imageURL]];
    if (self.camera.sourceURL.length) [lines addObject:[NSString stringWithFormat:@"Source page: %@", self.camera.sourceURL]];
    return [lines componentsJoinedByString:@"\n\n"];
}

@end
