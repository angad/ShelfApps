#import "FlightViewController.h"
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

static NSString * const OFDistanceThresholdKey = @"OFDistanceThresholdNM";
static NSString * const OFRefreshIntervalKey = @"OFRefreshIntervalSeconds";
static NSString * const OFRotationIntervalKey = @"OFRotationIntervalSeconds";
static NSString * const OFMaxFlightsKey = @"OFMaxFlights";
static NSString * const OFMaxSeenPositionKey = @"OFMaxSeenPositionSeconds";
static NSString * const OFMapFocusModeKey = @"OFMapFocusMode";
static NSString * const OFShowUnknownAirlinesKey = @"OFShowUnknownAirlines";
static double const OFEarthRadiusNM = 3440.065;

typedef NS_ENUM(NSInteger, OFMapFocusMode) {
    OFMapFocusModeUser = 0,
    OFMapFocusModeAircraft = 1,
    OFMapFocusModeDestination = 2,
    OFMapFocusModeOrigin = 3,
    OFMapFocusModeRoute = 4
};

@protocol SettingsViewControllerDelegate <NSObject>
- (void)settingsDidChange;
@end

@interface FlightMapAnnotation : NSObject <MKAnnotation>
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *kind;
@end

@implementation FlightMapAnnotation
@end

@interface AircraftDetailViewController : UIViewController

- (instancetype)initWithFlight:(NSDictionary *)flight session:(NSURLSession *)session;

@property (nonatomic, copy) NSDictionary *flight;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) UIImageView *photoView;
@property (nonatomic, strong) UILabel *photoCreditLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *registrationValueLabel;
@property (nonatomic, strong) UILabel *modeSValueLabel;
@property (nonatomic, strong) UILabel *typeValueLabel;
@property (nonatomic, strong) UILabel *manufacturerValueLabel;
@property (nonatomic, strong) UILabel *ownerValueLabel;
@property (nonatomic, strong) UILabel *countryValueLabel;
@property (nonatomic, strong) UILabel *flightValueLabel;
@property (nonatomic, strong) UILabel *detailDistanceValueLabel;
@property (nonatomic, strong) UILabel *detailAltitudeValueLabel;
@property (nonatomic, strong) UILabel *detailSpeedValueLabel;
@property (nonatomic, strong) UILabel *detailHeadingValueLabel;
@property (nonatomic, strong) UIButton *photoSourceButton;
@property (nonatomic, strong) UIButton *aircraftSourceButton;
@property (nonatomic, strong) UIButton *liveTrackButton;
@property (nonatomic, strong) NSURL *photoSourceURL;
@property (nonatomic, strong) NSURL *aircraftSourceURL;
@property (nonatomic, strong) NSURL *liveTrackURL;

@end

@implementation AircraftDetailViewController

- (instancetype)initWithFlight:(NSDictionary *)flight session:(NSURLSession *)session {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _flight = [flight copy];
        _session = session ?: [NSURLSession sharedSession];
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.030 green:0.036 blue:0.044 alpha:1.0];
    [self configureView];
    [self renderInitialState];
    [self fetchAircraftDetails];
    [self fetchPhoto];
}

- (void)configureView {
    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [doneButton setTitle:@"Done" forState:UIControlStateNormal];
    doneButton.tintColor = [UIColor whiteColor];
    doneButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:doneButton];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [scrollView addSubview:stack];

    self.photoView = [[UIImageView alloc] init];
    self.photoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.photoView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    self.photoView.contentMode = UIViewContentModeScaleAspectFill;
    self.photoView.clipsToBounds = YES;
    self.photoView.layer.cornerRadius = 8;
    self.photoView.layer.borderWidth = 1;
    self.photoView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    [stack addArrangedSubview:self.photoView];
    [self.photoView.heightAnchor constraintEqualToConstant:190].active = YES;

    self.photoCreditLabel = [self labelWithSize:10 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.50 alpha:1.0]];
    self.photoCreditLabel.textAlignment = NSTextAlignmentRight;
    [stack addArrangedSubview:self.photoCreditLabel];

    self.titleLabel = [self labelWithSize:30 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.55;
    [stack addArrangedSubview:self.titleLabel];

    self.subtitleLabel = [self labelWithSize:15 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.68 alpha:1.0]];
    [stack addArrangedSubview:self.subtitleLabel];

    self.statusLabel = [self labelWithSize:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.55 alpha:1.0]];
    [stack addArrangedSubview:self.statusLabel];

    UIView *identityPanel = [self panelView];
    [stack addArrangedSubview:identityPanel];
    [identityPanel.heightAnchor constraintEqualToConstant:198].active = YES;

    self.registrationValueLabel = [self valueLabel];
    self.modeSValueLabel = [self valueLabel];
    self.typeValueLabel = [self valueLabel];
    self.manufacturerValueLabel = [self valueLabel];
    self.ownerValueLabel = [self valueLabel];
    self.countryValueLabel = [self valueLabel];

    NSArray *rows = @[
        [self rowWithTitle:@"REGISTRATION" valueLabel:self.registrationValueLabel],
        [self rowWithTitle:@"ICAO HEX" valueLabel:self.modeSValueLabel],
        [self rowWithTitle:@"AIRCRAFT" valueLabel:self.typeValueLabel],
        [self rowWithTitle:@"MAKER" valueLabel:self.manufacturerValueLabel],
        [self rowWithTitle:@"OWNER" valueLabel:self.ownerValueLabel],
        [self rowWithTitle:@"COUNTRY" valueLabel:self.countryValueLabel]
    ];
    [self layoutRows:rows inPanel:identityPanel];

    UIView *flightPanel = [self panelView];
    [stack addArrangedSubview:flightPanel];
    [flightPanel.heightAnchor constraintEqualToConstant:168].active = YES;
    self.flightValueLabel = [self valueLabel];
    UIView *flightRow = [self rowWithTitle:@"CURRENT FLIGHT" valueLabel:self.flightValueLabel];
    [flightPanel addSubview:flightRow];

    self.detailDistanceValueLabel = [self compactValueLabel];
    self.detailAltitudeValueLabel = [self compactValueLabel];
    self.detailSpeedValueLabel = [self compactValueLabel];
    self.detailHeadingValueLabel = [self compactValueLabel];
    NSArray *metricBlocks = @[
        [self detailMetricBlockWithTitle:@"DISTANCE" valueLabel:self.detailDistanceValueLabel],
        [self detailMetricBlockWithTitle:@"ALTITUDE" valueLabel:self.detailAltitudeValueLabel],
        [self detailMetricBlockWithTitle:@"SPEED" valueLabel:self.detailSpeedValueLabel],
        [self detailMetricBlockWithTitle:@"HEADING" valueLabel:self.detailHeadingValueLabel]
    ];
    for (UIView *block in metricBlocks) {
        [flightPanel addSubview:block];
    }

    UIView *topLeft = metricBlocks[0];
    UIView *topRight = metricBlocks[1];
    UIView *bottomLeft = metricBlocks[2];
    UIView *bottomRight = metricBlocks[3];
    [NSLayoutConstraint activateConstraints:@[
        [flightRow.leadingAnchor constraintEqualToAnchor:flightPanel.leadingAnchor constant:14],
        [flightRow.trailingAnchor constraintEqualToAnchor:flightPanel.trailingAnchor constant:-14],
        [flightRow.topAnchor constraintEqualToAnchor:flightPanel.topAnchor constant:13],
        [flightRow.heightAnchor constraintEqualToConstant:36],

        [topLeft.leadingAnchor constraintEqualToAnchor:flightPanel.leadingAnchor constant:14],
        [topLeft.topAnchor constraintEqualToAnchor:flightRow.bottomAnchor constant:16],
        [topLeft.widthAnchor constraintEqualToAnchor:flightPanel.widthAnchor multiplier:0.43],
        [topLeft.heightAnchor constraintEqualToConstant:40],

        [topRight.trailingAnchor constraintEqualToAnchor:flightPanel.trailingAnchor constant:-14],
        [topRight.topAnchor constraintEqualToAnchor:topLeft.topAnchor],
        [topRight.widthAnchor constraintEqualToAnchor:topLeft.widthAnchor],
        [topRight.heightAnchor constraintEqualToAnchor:topLeft.heightAnchor],

        [bottomLeft.leadingAnchor constraintEqualToAnchor:topLeft.leadingAnchor],
        [bottomLeft.topAnchor constraintEqualToAnchor:topLeft.bottomAnchor constant:12],
        [bottomLeft.widthAnchor constraintEqualToAnchor:topLeft.widthAnchor],
        [bottomLeft.heightAnchor constraintEqualToAnchor:topLeft.heightAnchor],

        [bottomRight.trailingAnchor constraintEqualToAnchor:topRight.trailingAnchor],
        [bottomRight.topAnchor constraintEqualToAnchor:bottomLeft.topAnchor],
        [bottomRight.widthAnchor constraintEqualToAnchor:topRight.widthAnchor],
        [bottomRight.heightAnchor constraintEqualToAnchor:bottomLeft.heightAnchor]
    ]];

    self.liveTrackButton = [self sourceButtonWithTitle:@"Open live track"];
    [self.liveTrackButton addTarget:self action:@selector(openLiveTrack) forControlEvents:UIControlEventTouchUpInside];
    self.liveTrackButton.hidden = YES;
    [stack addArrangedSubview:self.liveTrackButton];

    self.photoSourceButton = [self sourceButtonWithTitle:@"Open photo source"];
    [self.photoSourceButton addTarget:self action:@selector(openPhotoSource) forControlEvents:UIControlEventTouchUpInside];
    self.photoSourceButton.hidden = YES;
    [stack addArrangedSubview:self.photoSourceButton];

    self.aircraftSourceButton = [self sourceButtonWithTitle:@"Open aircraft source"];
    [self.aircraftSourceButton addTarget:self action:@selector(openAircraftSource) forControlEvents:UIControlEventTouchUpInside];
    self.aircraftSourceButton.hidden = YES;
    [stack addArrangedSubview:self.aircraftSourceButton];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [doneButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [doneButton.topAnchor constraintEqualToAnchor:guide.topAnchor constant:14],

        [scrollView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:doneButton.bottomAnchor constant:10],
        [scrollView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],

        [stack.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:scrollView.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor constant:-36]
    ]];
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UILabel *)valueLabel {
    UILabel *label = [self labelWithSize:14 weight:UIFontWeightSemibold color:[UIColor whiteColor]];
    label.textAlignment = NSTextAlignmentRight;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.65;
    return label;
}

- (UILabel *)compactValueLabel {
    UILabel *label = [self labelWithSize:16 weight:UIFontWeightBold color:[UIColor whiteColor]];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.60;
    return label;
}

- (UIView *)detailMetricBlockWithTitle:(NSString *)title valueLabel:(UILabel *)valueLabel {
    UIView *block = [[UIView alloc] init];
    block.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *titleLabel = [self labelWithSize:10 weight:UIFontWeightBold color:[UIColor colorWithWhite:0.50 alpha:1.0]];
    titleLabel.text = title;
    [block addSubview:titleLabel];
    [block addSubview:valueLabel];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:block.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:block.trailingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:block.topAnchor],
        [valueLabel.leadingAnchor constraintEqualToAnchor:block.leadingAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:block.trailingAnchor],
        [valueLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [valueLabel.bottomAnchor constraintLessThanOrEqualToAnchor:block.bottomAnchor]
    ]];
    return block;
}

- (UIView *)panelView {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.88];
    panel.layer.cornerRadius = 8;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    return panel;
}

- (UIView *)rowWithTitle:(NSString *)title valueLabel:(UILabel *)valueLabel {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *titleLabel = [self labelWithSize:10 weight:UIFontWeightBold color:[UIColor colorWithRed:0.42 green:0.86 blue:0.96 alpha:1.0]];
    titleLabel.text = title;
    [row addSubview:titleLabel];
    [row addSubview:valueLabel];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [titleLabel.widthAnchor constraintEqualToConstant:92],
        [valueLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:10],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    return row;
}

- (void)layoutRows:(NSArray<UIView *> *)rows inPanel:(UIView *)panel {
    UIView *previous = nil;
    for (UIView *row in rows) {
        [panel addSubview:row];
        NSMutableArray *constraints = [NSMutableArray arrayWithObjects:
            [row.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
            [row.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
            [row.heightAnchor constraintEqualToConstant:26],
            nil];
        if (previous) {
            [constraints addObject:[row.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:3]];
        } else {
            [constraints addObject:[row.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14]];
        }
        [NSLayoutConstraint activateConstraints:constraints];
        previous = row;
    }
}

- (UIButton *)sourceButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithRed:0.45 green:0.90 blue:1.0 alpha:1.0];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    button.layer.cornerRadius = 6;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithRed:0.45 green:0.90 blue:1.0 alpha:0.35].CGColor;
    [button.heightAnchor constraintEqualToConstant:38].active = YES;
    return button;
}

- (void)renderInitialState {
    NSString *tail = [self stringOrNil:self.flight[@"tailNumber"]];
    NSString *hex = [self stringOrNil:self.flight[@"icaoHex"]];
    NSString *callsign = [self stringOrNil:self.flight[@"callsign"]] ?: @"Aircraft";
    self.titleLabel.text = tail ?: (hex ? [NSString stringWithFormat:@"ICAO %@", hex] : callsign);
    NSString *airline = [self stringOrNil:self.flight[@"airlineName"]];
    NSString *aircraftType = [self stringOrNil:self.flight[@"aircraftType"]];
    if (airline && aircraftType) {
        self.subtitleLabel.text = [NSString stringWithFormat:@"%@  |  %@", airline, aircraftType];
    } else {
        self.subtitleLabel.text = airline ?: (aircraftType ?: @"Aircraft profile");
    }
    self.statusLabel.text = @"Loading aircraft data and photos...";
    self.photoCreditLabel.text = @"";
    self.registrationValueLabel.text = tail ?: @"--";
    self.modeSValueLabel.text = hex ?: @"--";
    self.typeValueLabel.text = aircraftType ?: @"--";
    self.manufacturerValueLabel.text = @"--";
    self.ownerValueLabel.text = @"--";
    self.countryValueLabel.text = @"--";

    NSString *origin = [self stringOrNil:self.flight[@"originCode"]] ?: @"---";
    NSString *destination = [self stringOrNil:self.flight[@"destinationCode"]] ?: @"---";
    self.flightValueLabel.text = [NSString stringWithFormat:@"%@  %@ > %@", callsign, origin, destination];

    NSNumber *distance = [self.flight[@"distance"] isKindOfClass:[NSNumber class]] ? self.flight[@"distance"] : nil;
    NSNumber *speed = [self.flight[@"speed"] isKindOfClass:[NSNumber class]] ? self.flight[@"speed"] : nil;
    NSNumber *heading = [self.flight[@"heading"] isKindOfClass:[NSNumber class]] ? self.flight[@"heading"] : nil;
    self.detailDistanceValueLabel.text = distance ? [NSString stringWithFormat:@"%.1f nm", distance.doubleValue] : @"--";
    self.detailAltitudeValueLabel.text = [self stringOrNil:self.flight[@"altitude"]] ?: @"--";
    self.detailSpeedValueLabel.text = speed ? [NSString stringWithFormat:@"%.0f kt", speed.doubleValue] : @"--";
    self.detailHeadingValueLabel.text = heading ? [NSString stringWithFormat:@"%.0f deg", heading.doubleValue] : @"--";

    if (hex) {
        NSString *encodedHex = [hex stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        self.liveTrackURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://globe.adsb.lol/?icao=%@", encodedHex]];
        self.liveTrackButton.hidden = NO;
    }
}

- (void)fetchAircraftDetails {
    NSString *lookup = [self stringOrNil:self.flight[@"icaoHex"]] ?: [self stringOrNil:self.flight[@"tailNumber"]];
    if (!lookup) {
        self.statusLabel.text = @"No tail number or ICAO hex available for this aircraft.";
        return;
    }

    NSString *encoded = [lookup stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.adsbdb.com/v0/aircraft/%@", encoded]];
    self.aircraftSourceURL = url;
    self.aircraftSourceButton.hidden = NO;

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *aircraft = nil;
        if (!error && data.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *payload = [json isKindOfClass:[NSDictionary class]] ? json[@"response"] : nil;
            aircraft = [payload isKindOfClass:[NSDictionary class]] ? payload[@"aircraft"] : nil;
            if (![aircraft isKindOfClass:[NSDictionary class]]) {
                aircraft = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderAircraftDetails:aircraft error:error];
        });
    }];
    [task resume];
}

- (void)renderAircraftDetails:(NSDictionary *)aircraft error:(NSError *)error {
    if (!aircraft) {
        self.statusLabel.text = error ? [NSString stringWithFormat:@"Aircraft lookup failed: %@", error.localizedDescription] : @"No aircraft profile found.";
        return;
    }

    NSString *registration = [self stringOrNil:aircraft[@"registration"]];
    NSString *modeS = [self stringOrNil:aircraft[@"mode_s"]];
    NSString *type = [self stringOrNil:aircraft[@"type"]];
    NSString *icaoType = [self stringOrNil:aircraft[@"icao_type"]];
    NSString *manufacturer = [self stringOrNil:aircraft[@"manufacturer"]];
    NSString *owner = [self stringOrNil:aircraft[@"registered_owner"]];
    NSString *country = [self stringOrNil:aircraft[@"registered_owner_country_name"]];

    self.titleLabel.text = registration ?: self.titleLabel.text;
    self.registrationValueLabel.text = registration ?: self.registrationValueLabel.text;
    self.modeSValueLabel.text = modeS ?: self.modeSValueLabel.text;
    if (type && icaoType) {
        self.typeValueLabel.text = [NSString stringWithFormat:@"%@ / %@", type, icaoType];
    } else {
        self.typeValueLabel.text = type ?: (icaoType ?: self.typeValueLabel.text);
    }
    self.manufacturerValueLabel.text = manufacturer ?: @"--";
    self.ownerValueLabel.text = owner ?: @"--";
    self.countryValueLabel.text = country ?: @"--";
    self.statusLabel.text = @"Aircraft data from ADSBdb. Photos from Planespotters when available.";

    NSString *photoURLText = [self stringOrNil:aircraft[@"url_photo_thumbnail"]] ?: [self stringOrNil:aircraft[@"url_photo"]];
    if (photoURLText && !self.photoView.image) {
        [self loadPhotoURL:[NSURL URLWithString:photoURLText] credit:@"Photo via ADSBdb" sourceURL:[NSURL URLWithString:[self stringOrNil:aircraft[@"url_photo"]] ?: [self stringOrNil:aircraft[@"url_photo_thumbnail"]]]];
    }
}

- (void)fetchPhoto {
    NSString *tail = [self stringOrNil:self.flight[@"tailNumber"]];
    if (!tail) {
        self.photoCreditLabel.text = @"No registration available for photo lookup.";
        return;
    }

    NSString *encoded = [tail stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.planespotters.net/pub/photos/reg/%@", encoded]];
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *photo = nil;
        if (!error && data.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *photos = [json isKindOfClass:[NSDictionary class]] ? json[@"photos"] : nil;
            if ([photos isKindOfClass:[NSArray class]] && photos.count > 0 && [photos.firstObject isKindOfClass:[NSDictionary class]]) {
                photo = photos.firstObject;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderPlanespottersPhoto:photo error:error];
        });
    }];
    [task resume];
}

- (void)renderPlanespottersPhoto:(NSDictionary *)photo error:(NSError *)error {
    if (!photo) {
        if (!self.photoView.image) {
            self.photoCreditLabel.text = error ? @"Photo lookup failed." : @"No Planespotters photo found.";
        }
        return;
    }

    NSDictionary *large = [photo[@"thumbnail_large"] isKindOfClass:[NSDictionary class]] ? photo[@"thumbnail_large"] : nil;
    NSDictionary *small = [photo[@"thumbnail"] isKindOfClass:[NSDictionary class]] ? photo[@"thumbnail"] : nil;
    NSString *urlText = [self stringOrNil:large[@"src"]] ?: [self stringOrNil:small[@"src"]];
    NSString *credit = [self stringOrNil:photo[@"photographer"]];
    NSString *link = [self stringOrNil:photo[@"link"]];
    [self loadPhotoURL:[NSURL URLWithString:urlText]
                credit:credit ? [NSString stringWithFormat:@"Photo: %@", credit] : @"Photo via Planespotters"
             sourceURL:link ? [NSURL URLWithString:link] : nil];
}

- (void)loadPhotoURL:(NSURL *)url credit:(NSString *)credit sourceURL:(NSURL *)sourceURL {
    if (!url) {
        return;
    }
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = (!error && data.length > 0) ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) {
                self.photoView.image = image;
                self.photoCreditLabel.text = credit ?: @"";
                if (sourceURL) {
                    self.photoSourceURL = sourceURL;
                    self.photoSourceButton.hidden = NO;
                }
            }
        });
    }];
    [task resume];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openPhotoSource {
    if (self.photoSourceURL) {
        [[UIApplication sharedApplication] openURL:self.photoSourceURL options:@{} completionHandler:nil];
    }
}

- (void)openAircraftSource {
    if (self.aircraftSourceURL) {
        [[UIApplication sharedApplication] openURL:self.aircraftSourceURL options:@{} completionHandler:nil];
    }
}

- (void)openLiveTrack {
    if (self.liveTrackURL) {
        [[UIApplication sharedApplication] openURL:self.liveTrackURL options:@{} completionHandler:nil];
    }
}

- (NSString *)stringOrNil:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

@end

@interface SettingsViewController : UIViewController

@property (nonatomic, weak) id<SettingsViewControllerDelegate> delegate;
@property (nonatomic, strong) UISlider *distanceSlider;
@property (nonatomic, strong) UISlider *refreshSlider;
@property (nonatomic, strong) UISlider *rotationSlider;
@property (nonatomic, strong) UISlider *maxFlightsSlider;
@property (nonatomic, strong) UISlider *maxSeenSlider;
@property (nonatomic, strong) UISegmentedControl *mapFocusControl;
@property (nonatomic, strong) UISwitch *unknownAirlineSwitch;
@property (nonatomic, strong) UILabel *distanceValueLabel;
@property (nonatomic, strong) UILabel *refreshValueLabel;
@property (nonatomic, strong) UILabel *rotationValueLabel;
@property (nonatomic, strong) UILabel *maxFlightsValueLabel;
@property (nonatomic, strong) UILabel *maxSeenValueLabel;

@end

@interface FlightViewController () <CLLocationManagerDelegate, MKMapViewDelegate, SettingsViewControllerDelegate>

@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *routeCache;
@property (nonatomic, strong) CLLocation *currentLocation;
@property (nonatomic, copy) NSArray<NSDictionary *> *flights;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, strong) NSTimer *rotationTimer;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic) BOOL refreshing;

@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UIView *mapShadeView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UILabel *flightNumberLabel;
@property (nonatomic, strong) UILabel *airlineLabel;
@property (nonatomic, strong) UILabel *fromCodeLabel;
@property (nonatomic, strong) UILabel *fromNameLabel;
@property (nonatomic, strong) UILabel *toCodeLabel;
@property (nonatomic, strong) UILabel *toNameLabel;
@property (nonatomic, strong) UILabel *distanceValueLabel;
@property (nonatomic, strong) UILabel *altitudeValueLabel;
@property (nonatomic, strong) UILabel *speedValueLabel;
@property (nonatomic, strong) UILabel *headingValueLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *planeLinkButton;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) UIButton *refreshButton;

@end

@implementation SettingsViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.041 blue:0.047 alpha:1.0];
    [self configureView];
    [self loadValues];
    [self updateValueLabels];
}

- (void)configureView {
    UILabel *titleLabel = [self labelWithText:@"Settings" size:28 weight:UIFontWeightBold color:[UIColor whiteColor]];
    UILabel *subtitleLabel = [self labelWithText:@"Tune live aircraft filtering and refresh behavior." size:14 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.68 alpha:1.0]];
    subtitleLabel.numberOfLines = 0;

    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [doneButton setTitle:@"Done" forState:UIControlStateNormal];
    doneButton.tintColor = [UIColor whiteColor];
    doneButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [scrollView addSubview:stack];
    [self.view addSubview:doneButton];

    [stack addArrangedSubview:titleLabel];
    [stack addArrangedSubview:subtitleLabel];

    self.distanceSlider = [self sliderWithMin:1 max:80 action:@selector(sliderChanged)];
    self.refreshSlider = [self sliderWithMin:30 max:60 action:@selector(sliderChanged)];
    self.rotationSlider = [self sliderWithMin:3 max:12 action:@selector(sliderChanged)];
    self.maxFlightsSlider = [self sliderWithMin:1 max:20 action:@selector(sliderChanged)];
    self.maxSeenSlider = [self sliderWithMin:30 max:180 action:@selector(sliderChanged)];
    self.mapFocusControl = [[UISegmentedControl alloc] initWithItems:@[@"You", @"Plane", @"Dest", @"From", @"Route"]];
    self.mapFocusControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapFocusControl.tintColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.90 alpha:1.0];
    self.unknownAirlineSwitch = [[UISwitch alloc] init];
    self.unknownAirlineSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.unknownAirlineSwitch.onTintColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.90 alpha:1.0];

    self.distanceValueLabel = [self valueLabel];
    self.refreshValueLabel = [self valueLabel];
    self.rotationValueLabel = [self valueLabel];
    self.maxFlightsValueLabel = [self valueLabel];
    self.maxSeenValueLabel = [self valueLabel];

    [stack addArrangedSubview:[self settingsRowWithTitle:@"Distance threshold" detail:@"Aircraft search radius" valueLabel:self.distanceValueLabel slider:self.distanceSlider]];
    [stack addArrangedSubview:[self settingsRowWithTitle:@"Auto refresh" detail:@"Live ADS-B refresh interval" valueLabel:self.refreshValueLabel slider:self.refreshSlider]];
    [stack addArrangedSubview:[self settingsRowWithTitle:@"Screen rotation" detail:@"Seconds per aircraft" valueLabel:self.rotationValueLabel slider:self.rotationSlider]];
    [stack addArrangedSubview:[self settingsRowWithTitle:@"Max aircraft" detail:@"Limit route lookups and rotation count" valueLabel:self.maxFlightsValueLabel slider:self.maxFlightsSlider]];
    [stack addArrangedSubview:[self settingsRowWithTitle:@"Position freshness" detail:@"Ignore stale aircraft positions" valueLabel:self.maxSeenValueLabel slider:self.maxSeenSlider]];
    [stack addArrangedSubview:[self focusRowWithTitle:@"Map focus" detail:@"Auto-zoom target on refresh and rotation"]];
    [stack addArrangedSubview:[self switchRowWithTitle:@"Unknown airlines" detail:@"Show training, private, or unresolved aircraft" switchControl:self.unknownAirlineSwitch]];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [doneButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [doneButton.topAnchor constraintEqualToAnchor:guide.topAnchor constant:14],

        [scrollView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:doneButton.bottomAnchor constant:10],
        [scrollView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],

        [stack.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scrollView.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor constant:-40]
    ]];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

- (UILabel *)valueLabel {
    UILabel *label = [self labelWithText:@"" size:14 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.48 green:0.92 blue:1.0 alpha:1.0]];
    label.textAlignment = NSTextAlignmentRight;
    return label;
}

- (UISlider *)sliderWithMin:(float)min max:(float)max action:(SEL)action {
    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.tintColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.90 alpha:1.0];
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return slider;
}

- (UIView *)settingsRowWithTitle:(NSString *)title detail:(NSString *)detail valueLabel:(UILabel *)valueLabel slider:(UISlider *)slider {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.075];
    panel.layer.cornerRadius = 7;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;

    UILabel *titleLabel = [self labelWithText:title size:16 weight:UIFontWeightSemibold color:[UIColor whiteColor]];
    UILabel *detailLabel = [self labelWithText:detail size:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.58 alpha:1.0]];

    [panel addSubview:titleLabel];
    [panel addSubview:detailLabel];
    [panel addSubview:valueLabel];
    [panel addSubview:slider];

    [NSLayoutConstraint activateConstraints:@[
        [panel.heightAnchor constraintEqualToConstant:98],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:valueLabel.leadingAnchor constant:-10],

        [valueLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [valueLabel.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [valueLabel.widthAnchor constraintEqualToConstant:86],

        [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],

        [slider.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [slider.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [slider.topAnchor constraintEqualToAnchor:detailLabel.bottomAnchor constant:9]
    ]];
    return panel;
}

- (UIView *)switchRowWithTitle:(NSString *)title detail:(NSString *)detail switchControl:(UISwitch *)switchControl {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.075];
    panel.layer.cornerRadius = 7;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;

    UILabel *titleLabel = [self labelWithText:title size:16 weight:UIFontWeightSemibold color:[UIColor whiteColor]];
    UILabel *detailLabel = [self labelWithText:detail size:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    detailLabel.numberOfLines = 2;

    [panel addSubview:titleLabel];
    [panel addSubview:detailLabel];
    [panel addSubview:switchControl];

    [NSLayoutConstraint activateConstraints:@[
        [panel.heightAnchor constraintEqualToConstant:78],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:switchControl.leadingAnchor constant:-14],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],

        [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],

        [switchControl.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [switchControl.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor]
    ]];
    return panel;
}

- (UIView *)focusRowWithTitle:(NSString *)title detail:(NSString *)detail {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.075];
    panel.layer.cornerRadius = 7;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;

    UILabel *titleLabel = [self labelWithText:title size:16 weight:UIFontWeightSemibold color:[UIColor whiteColor]];
    UILabel *detailLabel = [self labelWithText:detail size:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.58 alpha:1.0]];

    [panel addSubview:titleLabel];
    [panel addSubview:detailLabel];
    [panel addSubview:self.mapFocusControl];

    [NSLayoutConstraint activateConstraints:@[
        [panel.heightAnchor constraintEqualToConstant:104],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12],

        [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],

        [self.mapFocusControl.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [self.mapFocusControl.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [self.mapFocusControl.topAnchor constraintEqualToAnchor:detailLabel.bottomAnchor constant:12],
        [self.mapFocusControl.heightAnchor constraintEqualToConstant:30]
    ]];
    return panel;
}

- (void)loadValues {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.distanceSlider.value = [self doubleForKey:OFDistanceThresholdKey fallback:15 defaults:defaults];
    self.refreshSlider.value = [self doubleForKey:OFRefreshIntervalKey fallback:45 defaults:defaults];
    self.rotationSlider.value = [self doubleForKey:OFRotationIntervalKey fallback:5 defaults:defaults];
    self.maxFlightsSlider.value = [self doubleForKey:OFMaxFlightsKey fallback:12 defaults:defaults];
    self.maxSeenSlider.value = [self doubleForKey:OFMaxSeenPositionKey fallback:90 defaults:defaults];
    self.mapFocusControl.selectedSegmentIndex = [defaults objectForKey:OFMapFocusModeKey] ? [defaults integerForKey:OFMapFocusModeKey] : OFMapFocusModeRoute;
    self.unknownAirlineSwitch.on = [defaults objectForKey:OFShowUnknownAirlinesKey] ? [defaults boolForKey:OFShowUnknownAirlinesKey] : YES;
}

- (double)doubleForKey:(NSString *)key fallback:(double)fallback defaults:(NSUserDefaults *)defaults {
    return [defaults objectForKey:key] ? [defaults doubleForKey:key] : fallback;
}

- (void)sliderChanged {
    [self updateValueLabels];
}

- (void)updateValueLabels {
    self.distanceValueLabel.text = [NSString stringWithFormat:@"%.0f nm", self.distanceSlider.value];
    self.refreshValueLabel.text = [NSString stringWithFormat:@"%.0f sec", self.refreshSlider.value];
    self.rotationValueLabel.text = [NSString stringWithFormat:@"%.0f sec", self.rotationSlider.value];
    self.maxFlightsValueLabel.text = [NSString stringWithFormat:@"%.0f", self.maxFlightsSlider.value];
    self.maxSeenValueLabel.text = [NSString stringWithFormat:@"%.0f sec", self.maxSeenSlider.value];
}

- (void)doneTapped {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:round(self.distanceSlider.value) forKey:OFDistanceThresholdKey];
    [defaults setDouble:round(self.refreshSlider.value) forKey:OFRefreshIntervalKey];
    [defaults setDouble:round(self.rotationSlider.value) forKey:OFRotationIntervalKey];
    [defaults setInteger:(NSInteger)round(self.maxFlightsSlider.value) forKey:OFMaxFlightsKey];
    [defaults setDouble:round(self.maxSeenSlider.value) forKey:OFMaxSeenPositionKey];
    [defaults setInteger:self.mapFocusControl.selectedSegmentIndex forKey:OFMapFocusModeKey];
    [defaults setBool:self.unknownAirlineSwitch.on forKey:OFShowUnknownAirlinesKey];
    [defaults synchronize];
    [self.delegate settingsDidChange];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@implementation FlightViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.session = [NSURLSession sharedSession];
    self.routeCache = [NSMutableDictionary dictionary];
    self.flights = @[];
    self.view.backgroundColor = [UIColor colorWithRed:0.018 green:0.022 blue:0.027 alpha:1.0];

    [self registerDefaults];
    [self configureView];
    [self configureLocation];
    [self showWaitingForLocation];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopTimers];
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        OFDistanceThresholdKey: @15,
        OFRefreshIntervalKey: @45,
        OFRotationIntervalKey: @5,
        OFMaxFlightsKey: @12,
        OFMaxSeenPositionKey: @90,
        OFMapFocusModeKey: @(OFMapFocusModeRoute),
        OFShowUnknownAirlinesKey: @YES
    }];
}

- (double)distanceThresholdNM {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:OFDistanceThresholdKey];
}

- (NSTimeInterval)refreshInterval {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:OFRefreshIntervalKey];
}

- (NSTimeInterval)rotationInterval {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:OFRotationIntervalKey];
}

- (NSInteger)maxFlights {
    return MAX(1, [[NSUserDefaults standardUserDefaults] integerForKey:OFMaxFlightsKey]);
}

- (double)maxSeenPositionSeconds {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:OFMaxSeenPositionKey];
}

- (OFMapFocusMode)mapFocusMode {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:OFMapFocusModeKey];
    if (value < OFMapFocusModeUser || value > OFMapFocusModeRoute) {
        return OFMapFocusModeRoute;
    }
    return (OFMapFocusMode)value;
}

- (BOOL)showUnknownAirlines {
    return [[NSUserDefaults standardUserDefaults] boolForKey:OFShowUnknownAirlinesKey];
}

- (void)configureView {
    self.mapView = [[MKMapView alloc] init];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.delegate = self;
    self.mapView.userInteractionEnabled = NO;
    self.mapView.pitchEnabled = NO;
    self.mapView.rotateEnabled = NO;
    self.mapView.scrollEnabled = NO;
    self.mapView.zoomEnabled = NO;
    self.mapView.mapType = MKMapTypeMutedStandard;
    self.mapView.alpha = 0.78;
    [self.view addSubview:self.mapView];

    self.mapShadeView = [[UIView alloc] init];
    self.mapShadeView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapShadeView.userInteractionEnabled = NO;
    self.mapShadeView.backgroundColor = [UIColor colorWithRed:0.0 green:0.02 blue:0.03 alpha:0.18];
    [self.view addSubview:self.mapShadeView];

    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentView];

    self.settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.settingsButton setImage:[self gearIconImageWithSize:CGSizeMake(24, 24)] forState:UIControlStateNormal];
    self.settingsButton.accessibilityLabel = @"Settings";
    self.settingsButton.tintColor = [UIColor whiteColor];
    self.settingsButton.contentEdgeInsets = UIEdgeInsetsZero;
    self.settingsButton.layer.cornerRadius = 6;
    self.settingsButton.layer.borderWidth = 1;
    self.settingsButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [self.settingsButton addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.settingsButton];

    self.refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.refreshButton setImage:[self refreshIconImageWithSize:CGSizeMake(24, 24)] forState:UIControlStateNormal];
    self.refreshButton.accessibilityLabel = @"Refresh";
    self.refreshButton.tintColor = [UIColor whiteColor];
    self.refreshButton.contentEdgeInsets = UIEdgeInsetsZero;
    self.refreshButton.layer.cornerRadius = 6;
    self.refreshButton.layer.borderWidth = 1;
    self.refreshButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [self.refreshButton addTarget:self action:@selector(refreshButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.refreshButton];

    self.flightNumberLabel = [self labelWithSize:48 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    self.flightNumberLabel.adjustsFontSizeToFitWidth = YES;
    self.flightNumberLabel.minimumScaleFactor = 0.42;
    self.airlineLabel = [self labelWithSize:17 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.72 alpha:1.0]];

    [self.contentView addSubview:self.flightNumberLabel];
    [self.contentView addSubview:self.airlineLabel];

    UIView *routePanel = [self panelView];
    [self.contentView addSubview:routePanel];

    UILabel *fromTitle = [self smallTitleLabel:@"FROM"];
    UILabel *toTitle = [self smallTitleLabel:@"TO"];
    self.fromCodeLabel = [self codeLabel];
    self.toCodeLabel = [self codeLabel];
    self.fromNameLabel = [self bodyLabel];
    self.toNameLabel = [self bodyLabel];

    [routePanel addSubview:fromTitle];
    [routePanel addSubview:self.fromCodeLabel];
    [routePanel addSubview:self.fromNameLabel];
    [routePanel addSubview:toTitle];
    [routePanel addSubview:self.toCodeLabel];
    [routePanel addSubview:self.toNameLabel];

    UIView *metricsPanel = [self panelView];
    [self.contentView addSubview:metricsPanel];

    self.distanceValueLabel = [self metricValueLabel];
    self.altitudeValueLabel = [self metricValueLabel];
    self.speedValueLabel = [self metricValueLabel];
    self.headingValueLabel = [self metricValueLabel];

    NSArray *metricBlocks = @[
        [self metricBlockWithTitle:@"DISTANCE" valueLabel:self.distanceValueLabel],
        [self metricBlockWithTitle:@"ALTITUDE" valueLabel:self.altitudeValueLabel],
        [self metricBlockWithTitle:@"SPEED" valueLabel:self.speedValueLabel],
        [self metricBlockWithTitle:@"HEADING" valueLabel:self.headingValueLabel]
    ];
    for (UIView *block in metricBlocks) {
        [metricsPanel addSubview:block];
    }

    self.statusLabel = [self labelWithSize:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.57 alpha:1.0]];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;

    self.planeLinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.planeLinkButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.planeLinkButton setImage:[self airplaneIconImageWithSize:CGSizeMake(24, 24)] forState:UIControlStateNormal];
    self.planeLinkButton.accessibilityLabel = @"Aircraft details";
    self.planeLinkButton.tintColor = [UIColor whiteColor];
    self.planeLinkButton.contentEdgeInsets = UIEdgeInsetsZero;
    self.planeLinkButton.layer.cornerRadius = 6;
    self.planeLinkButton.layer.borderWidth = 1;
    self.planeLinkButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [self.planeLinkButton addTarget:self action:@selector(planeLinkTapped) forControlEvents:UIControlEventTouchUpInside];
    self.planeLinkButton.hidden = YES;

    [self.contentView addSubview:self.planeLinkButton];
    [self.contentView addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.mapView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.mapView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.54],

        [self.mapShadeView.leadingAnchor constraintEqualToAnchor:self.mapView.leadingAnchor],
        [self.mapShadeView.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor],
        [self.mapShadeView.topAnchor constraintEqualToAnchor:self.mapView.topAnchor],
        [self.mapShadeView.bottomAnchor constraintEqualToAnchor:self.mapView.bottomAnchor],

        [self.contentView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.settingsButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
        [self.settingsButton.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:18],
        [self.settingsButton.widthAnchor constraintEqualToConstant:40],
        [self.settingsButton.heightAnchor constraintEqualToConstant:36],

        [self.refreshButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:18],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:self.settingsButton.centerYAnchor],
        [self.refreshButton.widthAnchor constraintEqualToConstant:40],
        [self.refreshButton.heightAnchor constraintEqualToConstant:36],

        [self.flightNumberLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:18],
        [self.flightNumberLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
        [self.flightNumberLabel.topAnchor constraintEqualToAnchor:self.settingsButton.bottomAnchor constant:24],

        [self.airlineLabel.leadingAnchor constraintEqualToAnchor:self.flightNumberLabel.leadingAnchor],
        [self.airlineLabel.trailingAnchor constraintEqualToAnchor:self.flightNumberLabel.trailingAnchor],
        [self.airlineLabel.topAnchor constraintEqualToAnchor:self.flightNumberLabel.bottomAnchor constant:2],

        [routePanel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [routePanel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [routePanel.topAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:8],
        [routePanel.heightAnchor constraintEqualToConstant:132],

        [fromTitle.leadingAnchor constraintEqualToAnchor:routePanel.leadingAnchor constant:16],
        [fromTitle.topAnchor constraintEqualToAnchor:routePanel.topAnchor constant:12],
        [self.fromCodeLabel.leadingAnchor constraintEqualToAnchor:fromTitle.leadingAnchor],
        [self.fromCodeLabel.topAnchor constraintEqualToAnchor:fromTitle.bottomAnchor constant:2],
        [self.fromCodeLabel.widthAnchor constraintEqualToConstant:82],
        [self.fromNameLabel.leadingAnchor constraintEqualToAnchor:routePanel.leadingAnchor constant:132],
        [self.fromNameLabel.trailingAnchor constraintEqualToAnchor:routePanel.trailingAnchor constant:-16],
        [self.fromNameLabel.topAnchor constraintEqualToAnchor:routePanel.topAnchor constant:12],
        [self.fromNameLabel.heightAnchor constraintEqualToConstant:48],

        [toTitle.leadingAnchor constraintEqualToAnchor:routePanel.leadingAnchor constant:16],
        [toTitle.topAnchor constraintEqualToAnchor:routePanel.topAnchor constant:72],
        [self.toCodeLabel.leadingAnchor constraintEqualToAnchor:toTitle.leadingAnchor],
        [self.toCodeLabel.topAnchor constraintEqualToAnchor:toTitle.bottomAnchor constant:2],
        [self.toCodeLabel.widthAnchor constraintEqualToConstant:82],
        [self.toNameLabel.leadingAnchor constraintEqualToAnchor:self.fromNameLabel.leadingAnchor],
        [self.toNameLabel.trailingAnchor constraintEqualToAnchor:routePanel.trailingAnchor constant:-16],
        [self.toNameLabel.topAnchor constraintEqualToAnchor:routePanel.topAnchor constant:72],
        [self.toNameLabel.heightAnchor constraintEqualToConstant:48],

        [metricsPanel.leadingAnchor constraintEqualToAnchor:routePanel.leadingAnchor],
        [metricsPanel.trailingAnchor constraintEqualToAnchor:routePanel.trailingAnchor],
        [metricsPanel.topAnchor constraintEqualToAnchor:routePanel.bottomAnchor constant:10],
        [metricsPanel.heightAnchor constraintEqualToConstant:132],

        [self.planeLinkButton.trailingAnchor constraintEqualToAnchor:self.settingsButton.leadingAnchor constant:-10],
        [self.planeLinkButton.centerYAnchor constraintEqualToAnchor:self.settingsButton.centerYAnchor],
        [self.planeLinkButton.widthAnchor constraintEqualToConstant:40],
        [self.planeLinkButton.heightAnchor constraintEqualToConstant:36],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [self.statusLabel.topAnchor constraintEqualToAnchor:metricsPanel.bottomAnchor constant:6],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14]
    ]];

    [self layoutMetricBlocks:metricBlocks inPanel:metricsPanel];
}

- (void)layoutMetricBlocks:(NSArray<UIView *> *)blocks inPanel:(UIView *)panel {
    UIView *topLeft = blocks[0];
    UIView *topRight = blocks[1];
    UIView *bottomLeft = blocks[2];
    UIView *bottomRight = blocks[3];

    [NSLayoutConstraint activateConstraints:@[
        [topLeft.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [topLeft.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16],
        [topLeft.widthAnchor constraintEqualToAnchor:panel.widthAnchor multiplier:0.45],
        [topLeft.heightAnchor constraintEqualToConstant:48],

        [topRight.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [topRight.topAnchor constraintEqualToAnchor:topLeft.topAnchor],
        [topRight.widthAnchor constraintEqualToAnchor:topLeft.widthAnchor],
        [topRight.heightAnchor constraintEqualToAnchor:topLeft.heightAnchor],

        [bottomLeft.leadingAnchor constraintEqualToAnchor:topLeft.leadingAnchor],
        [bottomLeft.topAnchor constraintEqualToAnchor:topLeft.bottomAnchor constant:14],
        [bottomLeft.widthAnchor constraintEqualToAnchor:topLeft.widthAnchor],
        [bottomLeft.heightAnchor constraintEqualToAnchor:topLeft.heightAnchor],

        [bottomRight.trailingAnchor constraintEqualToAnchor:topRight.trailingAnchor],
        [bottomRight.topAnchor constraintEqualToAnchor:bottomLeft.topAnchor],
        [bottomRight.widthAnchor constraintEqualToAnchor:topLeft.widthAnchor],
        [bottomRight.heightAnchor constraintEqualToAnchor:topLeft.heightAnchor]
    ]];
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UILabel *)smallTitleLabel:(NSString *)text {
    UILabel *label = [self labelWithSize:11 weight:UIFontWeightBold color:[UIColor colorWithRed:0.43 green:0.86 blue:0.96 alpha:1.0]];
    label.text = text;
    return label;
}

- (UILabel *)codeLabel {
    UILabel *label = [self labelWithSize:28 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.60;
    return label;
}

- (UILabel *)bodyLabel {
    UILabel *label = [self labelWithSize:15 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.82 alpha:1.0]];
    label.numberOfLines = 2;
    return label;
}

- (UILabel *)metricValueLabel {
    UILabel *label = [self labelWithSize:22 weight:UIFontWeightBold color:[UIColor whiteColor]];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.55;
    return label;
}

- (UIView *)panelView {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.86];
    panel.layer.cornerRadius = 8;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    return panel;
}

- (UIView *)metricBlockWithTitle:(NSString *)title valueLabel:(UILabel *)valueLabel {
    UIView *block = [[UIView alloc] init];
    block.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *titleLabel = [self smallTitleLabel:title];
    titleLabel.textColor = [UIColor colorWithWhite:0.52 alpha:1.0];
    [block addSubview:titleLabel];
    [block addSubview:valueLabel];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:block.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:block.trailingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:block.topAnchor],
        [valueLabel.leadingAnchor constraintEqualToAnchor:block.leadingAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:block.trailingAnchor],
        [valueLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [valueLabel.bottomAnchor constraintLessThanOrEqualToAnchor:block.bottomAnchor]
    ]];
    return block;
}

- (UIImage *)gearIconImageWithSize:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, size.width / 2.0, size.height / 2.0);

    CGFloat outerRadius = MIN(size.width, size.height) * 0.46;
    CGFloat innerRadius = outerRadius * 0.72;
    UIBezierPath *gear = [UIBezierPath bezierPath];
    NSInteger teeth = 8;
    for (NSInteger index = 0; index < teeth * 2; index++) {
        CGFloat radius = (index % 2 == 0) ? outerRadius : innerRadius;
        CGFloat angle = ((CGFloat)index / (CGFloat)(teeth * 2)) * (CGFloat)(M_PI * 2.0) - (CGFloat)(M_PI_2);
        CGPoint point = CGPointMake(cos(angle) * radius, sin(angle) * radius);
        if (index == 0) {
            [gear moveToPoint:point];
        } else {
            [gear addLineToPoint:point];
        }
    }
    [gear closePath];

    UIBezierPath *center = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-outerRadius * 0.33,
                                                                             -outerRadius * 0.33,
                                                                             outerRadius * 0.66,
                                                                             outerRadius * 0.66)];
    [gear appendPath:center];
    gear.usesEvenOddFillRule = YES;

    [[UIColor whiteColor] setFill];
    [gear fill];
    UIImage *image = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)refreshIconImageWithSize:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, size.width / 2.0, size.height / 2.0);

    CGFloat radius = MIN(size.width, size.height) * 0.31;
    CGFloat startAngle = (CGFloat)(-M_PI * 0.25);
    CGFloat endAngle = (CGFloat)(M_PI * 1.45);
    UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointZero
                                                       radius:radius
                                                   startAngle:startAngle
                                                     endAngle:endAngle
                                                    clockwise:YES];
    arc.lineWidth = 2.6;
    arc.lineCapStyle = kCGLineCapRound;
    [[UIColor whiteColor] setStroke];
    [arc stroke];

    CGPoint tip = CGPointMake(cos(endAngle) * radius, sin(endAngle) * radius);
    CGFloat tangent = endAngle + (CGFloat)M_PI_2;
    CGFloat back = tangent + (CGFloat)M_PI;
    CGFloat spread = 0.72;
    CGFloat length = 6.6;
    CGPoint left = CGPointMake(tip.x + cos(back - spread) * length,
                               tip.y + sin(back - spread) * length);
    CGPoint right = CGPointMake(tip.x + cos(back + spread) * length,
                                tip.y + sin(back + spread) * length);
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:tip];
    [arrow addLineToPoint:left];
    [arrow addLineToPoint:right];
    [arrow closePath];
    [[UIColor whiteColor] setFill];
    [arrow fill];

    UIImage *image = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)airplaneIconImageWithSize:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    UIBezierPath *plane = [UIBezierPath bezierPath];
    CGFloat midY = size.height * 0.50;
    [plane moveToPoint:CGPointMake(size.width * 0.16, midY)];
    [plane addLineToPoint:CGPointMake(size.width * 0.84, midY)];
    [plane moveToPoint:CGPointMake(size.width * 0.48, midY)];
    [plane addLineToPoint:CGPointMake(size.width * 0.26, size.height * 0.22)];
    [plane moveToPoint:CGPointMake(size.width * 0.48, midY)];
    [plane addLineToPoint:CGPointMake(size.width * 0.26, size.height * 0.78)];
    [plane moveToPoint:CGPointMake(size.width * 0.24, midY)];
    [plane addLineToPoint:CGPointMake(size.width * 0.12, size.height * 0.34)];
    [plane moveToPoint:CGPointMake(size.width * 0.24, midY)];
    [plane addLineToPoint:CGPointMake(size.width * 0.12, size.height * 0.66)];
    plane.lineWidth = 2.7;
    plane.lineCapStyle = kCGLineCapRound;
    plane.lineJoinStyle = kCGLineJoinRound;
    [[UIColor whiteColor] setStroke];
    [plane stroke];

    UIBezierPath *nose = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(size.width * 0.80,
                                                                            midY - 1.35,
                                                                            2.7,
                                                                            2.7)];
    [[UIColor whiteColor] setFill];
    [nose fill];

    UIImage *image = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();
    return image;
}

- (void)configureLocation {
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    self.locationManager.distanceFilter = 500;

    if (![CLLocationManager locationServicesEnabled]) {
        [self renderStatusTitle:@"Location Off" message:@"Enable Location Services in Settings."];
        return;
    }

    [self handleAuthorization:[CLLocationManager authorizationStatus]];
}

- (void)handleAuthorization:(CLAuthorizationStatus)status {
    switch (status) {
        case kCLAuthorizationStatusNotDetermined:
            [self.locationManager requestWhenInUseAuthorization];
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            [self.locationManager startUpdatingLocation];
            [self.locationManager requestLocation];
            [self startTimers];
            break;
        case kCLAuthorizationStatusDenied:
        case kCLAuthorizationStatusRestricted:
            [self renderStatusTitle:@"Location Needed" message:@"Allow location access in Settings to find flights overhead."];
            break;
    }
}

- (void)startTimers {
    [self stopTimers];
    self.rotationTimer = [NSTimer scheduledTimerWithTimeInterval:[self rotationInterval] target:self selector:@selector(advanceFlight) userInfo:nil repeats:YES];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:[self refreshInterval] target:self selector:@selector(refreshFlights) userInfo:nil repeats:YES];
}

- (void)stopTimers {
    [self.rotationTimer invalidate];
    [self.refreshTimer invalidate];
    self.rotationTimer = nil;
    self.refreshTimer = nil;
}

- (void)settingsTapped {
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    settings.delegate = self;
    [self presentViewController:settings animated:YES completion:nil];
}

- (void)settingsDidChange {
    [self startTimers];
    [self refreshFlights];
}

- (void)refreshButtonTapped {
    [self refreshFlights];
}

- (void)refreshFlights {
    if (!self.currentLocation) {
        [self.locationManager requestLocation];
        [self showWaitingForLocation];
        return;
    }
    if (self.refreshing) {
        return;
    }

    self.refreshing = YES;
    self.statusLabel.text = @"Refreshing live aircraft...";

    [self fetchFlightsNear:self.currentLocation completion:^(NSArray<NSDictionary *> *flights, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshing = NO;
            if (error) {
                self.statusLabel.text = [NSString stringWithFormat:@"Refresh failed: %@", error.localizedDescription];
                return;
            }

            self.flights = flights ?: @[];
            self.selectedIndex = 0;
            [self renderCurrentFlight];
        });
    }];
}

- (void)fetchFlightsNear:(CLLocation *)location completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSString *urlText = [NSString stringWithFormat:@"https://api.adsb.lol/v2/lat/%.6f/lon/%.6f/dist/%.0f",
                         location.coordinate.latitude,
                         location.coordinate.longitude,
                         [self distanceThresholdNM]];
    NSURL *url = [NSURL URLWithString:urlText];
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, jsonError);
            return;
        }

        NSArray *aircraft = json[@"ac"];
        if (![aircraft isKindOfClass:[NSArray class]]) {
            completion(@[], nil);
            return;
        }

        NSMutableArray<NSDictionary *> *cleanAircraft = [NSMutableArray array];
        for (NSDictionary *item in aircraft) {
            if (![item isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *callsign = [self cleanCallsign:item[@"flight"]];
            if (!callsign) {
                continue;
            }
            NSString *baroAltitudeText = [self stringOrNil:item[@"alt_baro"]];
            if (baroAltitudeText && [baroAltitudeText caseInsensitiveCompare:@"ground"] == NSOrderedSame) {
                continue;
            }
            NSNumber *seenPosition = [self numberFromObject:item[@"seen_pos"]];
            if (seenPosition && seenPosition.doubleValue > [self maxSeenPositionSeconds]) {
                continue;
            }
            [cleanAircraft addObject:item];
        }

        [cleanAircraft sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double left = [self numberFromObject:a[@"dst"]].doubleValue;
            double right = [self numberFromObject:b[@"dst"]].doubleValue;
            return left < right ? NSOrderedAscending : (left > right ? NSOrderedDescending : NSOrderedSame);
        }];

        NSInteger lookupLimit = [self maxFlights];
        if (![self showUnknownAirlines]) {
            lookupLimit = MIN((NSInteger)cleanAircraft.count, MAX(lookupLimit, lookupLimit * 3));
        }
        if (cleanAircraft.count > lookupLimit) {
            [cleanAircraft removeObjectsInRange:NSMakeRange(lookupLimit, cleanAircraft.count - lookupLimit)];
        }

        [self resolveRoutesForAircraft:cleanAircraft completion:completion];
    }];
    [task resume];
}

- (void)resolveRoutesForAircraft:(NSArray<NSDictionary *> *)aircraft completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    if (aircraft.count == 0) {
        completion(@[], nil);
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSDictionary *> *flights = [NSMutableArray array];
    NSObject *lock = [[NSObject alloc] init];

    for (NSDictionary *item in aircraft) {
        NSString *callsign = [self cleanCallsign:item[@"flight"]];
        if (!callsign) {
            continue;
        }

        dispatch_group_enter(group);
        [self lookupRouteForCallsign:callsign completion:^(NSDictionary *route) {
            if (route && ![self routeIsPlausible:route forAircraft:item]) {
                dispatch_group_leave(group);
                return;
            }

            NSDictionary *airline = [route[@"airline"] isKindOfClass:[NSDictionary class]] ? route[@"airline"] : nil;
            NSDictionary *origin = [route[@"origin"] isKindOfClass:[NSDictionary class]] ? route[@"origin"] : nil;
            NSDictionary *destination = [route[@"destination"] isKindOfClass:[NSDictionary class]] ? route[@"destination"] : nil;
            NSString *airlineName = [self stringOrNil:airline[@"name"]];
            if (!airlineName && ![self showUnknownAirlines]) {
                dispatch_group_leave(group);
                return;
            }

            NSString *displayCallsign = callsign;
            if (route) {
                NSString *iata = [self stringOrNil:route[@"callsign_iata"]];
                NSString *icao = [self stringOrNil:route[@"callsign_icao"]];
                displayCallsign = iata ?: (icao ?: callsign);
            }

            NSMutableDictionary *flight = [NSMutableDictionary dictionary];
            flight[@"id"] = [self stringOrNil:item[@"hex"]] ?: callsign;
            flight[@"callsign"] = displayCallsign;
            flight[@"airlineName"] = airlineName ?: @"Unknown airline";
            flight[@"originCode"] = [self airportCode:origin] ?: @"---";
            flight[@"originName"] = [self airportName:origin] ?: @"Origin unavailable";
            flight[@"destinationCode"] = [self airportCode:destination] ?: @"---";
            flight[@"destinationName"] = [self airportName:destination] ?: @"Destination unavailable";
            flight[@"altitude"] = [self altitudeTextFromObject:item[@"alt_baro"]] ?: @"--";
            flight[@"aircraftType"] = [self stringOrNil:item[@"t"]] ?: @"";
            NSString *tailNumber = [self stringOrNil:item[@"r"]];
            NSString *icaoHex = [self stringOrNil:item[@"hex"]];
            if (tailNumber) {
                flight[@"tailNumber"] = tailNumber.uppercaseString;
            }
            if (icaoHex) {
                flight[@"icaoHex"] = icaoHex.uppercaseString;
            }
            flight[@"updatedAt"] = [NSDate date];

            [self setNumberFrom:item[@"dst"] key:@"distance" inDictionary:flight];
            [self setNumberFrom:item[@"gs"] key:@"speed" inDictionary:flight];
            NSNumber *heading = [self nullableNumber:item[@"track"]] ?: [self nullableNumber:item[@"true_heading"]] ?: [self nullableNumber:item[@"mag_heading"]];
            if (heading) {
                flight[@"heading"] = heading;
            }
            [self setNumberFrom:item[@"lat"] key:@"planeLatitude" inDictionary:flight];
            [self setNumberFrom:item[@"lon"] key:@"planeLongitude" inDictionary:flight];
            [self setNumberFrom:origin[@"latitude"] key:@"originLatitude" inDictionary:flight];
            [self setNumberFrom:origin[@"longitude"] key:@"originLongitude" inDictionary:flight];
            [self setNumberFrom:destination[@"latitude"] key:@"destinationLatitude" inDictionary:flight];
            [self setNumberFrom:destination[@"longitude"] key:@"destinationLongitude" inDictionary:flight];

            @synchronized (lock) {
                [flights addObject:[flight copy]];
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [flights sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double left = [a[@"distance"] isKindOfClass:[NSNumber class]] ? [a[@"distance"] doubleValue] : DBL_MAX;
            double right = [b[@"distance"] isKindOfClass:[NSNumber class]] ? [b[@"distance"] doubleValue] : DBL_MAX;
            return left < right ? NSOrderedAscending : (left > right ? NSOrderedDescending : NSOrderedSame);
        }];
        NSInteger maxFlights = [self maxFlights];
        if (flights.count > maxFlights) {
            [flights removeObjectsInRange:NSMakeRange(maxFlights, flights.count - maxFlights)];
        }
        completion([flights copy], nil);
    });
}

- (void)lookupRouteForCallsign:(NSString *)callsign completion:(void (^)(NSDictionary *))completion {
    NSDictionary *cached = self.routeCache[callsign];
    NSDate *expiresAt = cached[@"expiresAt"];
    if ([expiresAt isKindOfClass:[NSDate class]] && [expiresAt timeIntervalSinceNow] > 0) {
        id route = cached[@"route"];
        completion([route isKindOfClass:[NSDictionary class]] ? route : nil);
        return;
    }

    NSString *encoded = [callsign stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.adsbdb.com/v0/callsign/%@", encoded]];
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *route = nil;
        if (!error && data.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *payload = [json isKindOfClass:[NSDictionary class]] ? json[@"response"] : nil;
            NSDictionary *candidate = [payload isKindOfClass:[NSDictionary class]] ? payload[@"flightroute"] : nil;
            if ([candidate isKindOfClass:[NSDictionary class]]) {
                route = candidate;
            }
        }

        @synchronized (self.routeCache) {
            self.routeCache[callsign] = @{
                @"route": route ?: [NSNull null],
                @"expiresAt": [NSDate dateWithTimeIntervalSinceNow:(60 * 60 * 6)]
            };
        }
        completion(route);
    }];
    [task resume];
}

- (void)advanceFlight {
    if (self.flights.count <= 1) {
        return;
    }
    self.selectedIndex = (self.selectedIndex + 1) % self.flights.count;
    [self renderCurrentFlight];
}

- (void)renderCurrentFlight {
    if (self.flights.count == 0) {
        [self renderStatusTitle:@"No Flights" message:@"No fresh ADS-B aircraft with callsigns found in range."];
        self.statusLabel.text = [NSString stringWithFormat:@"Search radius %.0f nm | unknown airlines %@",
                                 [self distanceThresholdNM],
                                 [self showUnknownAirlines] ? @"on" : @"off"];
        [self updatePlaneLinkForFlight:nil];
        [self updateMapForFlight:nil];
        return;
    }

    NSDictionary *flight = self.flights[MIN(self.selectedIndex, (NSInteger)self.flights.count - 1)];
    self.flightNumberLabel.text = flight[@"callsign"];
    NSString *airlineName = [self stringOrNil:flight[@"airlineName"]] ?: @"Unknown airline";
    NSString *aircraftType = [self stringOrNil:flight[@"aircraftType"]];
    self.airlineLabel.text = aircraftType ? [NSString stringWithFormat:@"%@  |  %@", airlineName, aircraftType] : airlineName;
    self.fromCodeLabel.text = flight[@"originCode"];
    self.fromNameLabel.text = flight[@"originName"];
    self.toCodeLabel.text = flight[@"destinationCode"];
    self.toNameLabel.text = flight[@"destinationName"];

    NSNumber *distance = [flight[@"distance"] isKindOfClass:[NSNumber class]] ? flight[@"distance"] : nil;
    self.distanceValueLabel.text = distance ? [NSString stringWithFormat:@"%.1f nm", distance.doubleValue] : @"--";
    self.altitudeValueLabel.text = [self stringOrNil:flight[@"altitude"]] ?: @"--";

    NSNumber *speed = [flight[@"speed"] isKindOfClass:[NSNumber class]] ? flight[@"speed"] : nil;
    self.speedValueLabel.text = speed ? [NSString stringWithFormat:@"%.0f kt", speed.doubleValue] : @"--";

    NSNumber *heading = [flight[@"heading"] isKindOfClass:[NSNumber class]] ? flight[@"heading"] : nil;
    self.headingValueLabel.text = heading ? [NSString stringWithFormat:@"%.0f deg", heading.doubleValue] : @"--";
    [self updatePlaneLinkForFlight:flight];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    NSString *timeText = [formatter stringFromDate:flight[@"updatedAt"]];
    if (self.flights.count == 1) {
        self.statusLabel.text = [NSString stringWithFormat:@"1 flight | updated %@ | %.0f nm radius",
                                 timeText,
                                 [self distanceThresholdNM]];
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"%ld of %lu | updated %@ | %.0f nm radius",
                                 (long)self.selectedIndex + 1,
                                 (unsigned long)self.flights.count,
                                 timeText,
                                 [self distanceThresholdNM]];
    }
    [self updateMapForFlight:flight];
}

- (void)renderStatusTitle:(NSString *)title message:(NSString *)message {
    self.flightNumberLabel.text = title;
    self.airlineLabel.text = message;
    self.fromCodeLabel.text = @"---";
    self.fromNameLabel.text = @"Waiting for route data";
    self.toCodeLabel.text = @"---";
    self.toNameLabel.text = @"Waiting for route data";
    self.distanceValueLabel.text = @"--";
    self.altitudeValueLabel.text = @"--";
    self.speedValueLabel.text = @"--";
    self.headingValueLabel.text = @"--";
    [self updatePlaneLinkForFlight:nil];
}

- (void)showWaitingForLocation {
    [self renderStatusTitle:@"Finding You" message:@"Allow location access when prompted."];
    self.statusLabel.text = @"Location is required to find aircraft overhead.";
}

- (void)updatePlaneLinkForFlight:(NSDictionary *)flight {
    NSString *tailNumber = [self stringOrNil:flight[@"tailNumber"]];
    NSString *icaoHex = [self stringOrNil:flight[@"icaoHex"]];
    if (!tailNumber && !icaoHex) {
        self.planeLinkButton.hidden = YES;
        self.planeLinkButton.accessibilityLabel = nil;
        [self.planeLinkButton setTitle:@"" forState:UIControlStateNormal];
        return;
    }

    NSString *identifier = tailNumber ?: (icaoHex ? [NSString stringWithFormat:@"ICAO %@", icaoHex] : @"Aircraft");
    [self.planeLinkButton setTitle:@"" forState:UIControlStateNormal];
    self.planeLinkButton.accessibilityLabel = [NSString stringWithFormat:@"Aircraft details for %@", identifier];
    self.planeLinkButton.hidden = NO;
}

- (void)planeLinkTapped {
    NSDictionary *flight = nil;
    if (self.flights.count > 0) {
        flight = self.flights[MIN(self.selectedIndex, (NSInteger)self.flights.count - 1)];
    }
    NSString *tailNumber = [self stringOrNil:flight[@"tailNumber"]];
    NSString *icaoHex = [self stringOrNil:flight[@"icaoHex"]];
    if (!tailNumber && !icaoHex) {
        return;
    }
    AircraftDetailViewController *detail = [[AircraftDetailViewController alloc] initWithFlight:flight session:self.session];
    [self presentViewController:detail animated:YES completion:nil];
}

- (void)updateMapForFlight:(NSDictionary *)flight {
    [self.mapView removeAnnotations:self.mapView.annotations];
    [self.mapView removeOverlays:self.mapView.overlays];

    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    if (self.currentLocation) {
        CLLocationCoordinate2D userCoordinate = self.currentLocation.coordinate;
        [points addObject:[NSValue valueWithMKCoordinate:userCoordinate]];
        [self addAnnotationAt:userCoordinate title:@"You" subtitle:@"Live location" kind:@"user"];
    }

    CLLocationCoordinate2D planeCoordinate;
    BOOL hasPlane = [self coordinate:&planeCoordinate latitude:flight[@"planeLatitude"] longitude:flight[@"planeLongitude"]];
    if (hasPlane) {
        [points addObject:[NSValue valueWithMKCoordinate:planeCoordinate]];
        [self addAnnotationAt:planeCoordinate title:flight[@"callsign"] subtitle:@"Live aircraft position" kind:@"plane"];
    }

    CLLocationCoordinate2D originCoordinate;
    BOOL hasOrigin = [self coordinate:&originCoordinate latitude:flight[@"originLatitude"] longitude:flight[@"originLongitude"]];
    CLLocationCoordinate2D destinationCoordinate;
    BOOL hasDestination = [self coordinate:&destinationCoordinate latitude:flight[@"destinationLatitude"] longitude:flight[@"destinationLongitude"]];

    if (hasOrigin) {
        [self addAnnotationAt:originCoordinate title:flight[@"originCode"] subtitle:flight[@"originName"] kind:@"origin"];
    }
    if (hasDestination) {
        [self addAnnotationAt:destinationCoordinate title:flight[@"destinationCode"] subtitle:flight[@"destinationName"] kind:@"destination"];
    }

    if (hasOrigin && hasPlane && hasDestination) {
        CLLocationCoordinate2D coordinates[3] = { originCoordinate, planeCoordinate, destinationCoordinate };
        [self.mapView addOverlay:[MKPolyline polylineWithCoordinates:coordinates count:3]];
        [points addObject:[NSValue valueWithMKCoordinate:originCoordinate]];
        [points addObject:[NSValue valueWithMKCoordinate:destinationCoordinate]];
    } else if (self.currentLocation && hasPlane) {
        CLLocationCoordinate2D coordinates[2] = { self.currentLocation.coordinate, planeCoordinate };
        [self.mapView addOverlay:[MKPolyline polylineWithCoordinates:coordinates count:2]];
    }

    [self updateMapCameraWithPoints:points
                      userCoordinate:self.currentLocation ? self.currentLocation.coordinate : kCLLocationCoordinate2DInvalid
                     planeCoordinate:hasPlane ? planeCoordinate : kCLLocationCoordinate2DInvalid
                    originCoordinate:hasOrigin ? originCoordinate : kCLLocationCoordinate2DInvalid
               destinationCoordinate:hasDestination ? destinationCoordinate : kCLLocationCoordinate2DInvalid];
}

- (void)addAnnotationAt:(CLLocationCoordinate2D)coordinate title:(NSString *)title subtitle:(NSString *)subtitle kind:(NSString *)kind {
    FlightMapAnnotation *annotation = [[FlightMapAnnotation alloc] init];
    annotation.coordinate = coordinate;
    annotation.title = title;
    annotation.subtitle = subtitle;
    annotation.kind = kind;
    [self.mapView addAnnotation:annotation];
}

- (void)updateMapCameraWithPoints:(NSArray<NSValue *> *)points
                    userCoordinate:(CLLocationCoordinate2D)userCoordinate
                   planeCoordinate:(CLLocationCoordinate2D)planeCoordinate
                  originCoordinate:(CLLocationCoordinate2D)originCoordinate
             destinationCoordinate:(CLLocationCoordinate2D)destinationCoordinate {
    switch ([self mapFocusMode]) {
        case OFMapFocusModeUser:
            if (CLLocationCoordinate2DIsValid(userCoordinate)) {
                [self centerMapOnCoordinate:userCoordinate radiusMeters:18000];
                return;
            }
            break;
        case OFMapFocusModeAircraft:
            if (CLLocationCoordinate2DIsValid(planeCoordinate)) {
                [self centerMapOnCoordinate:planeCoordinate radiusMeters:18000];
                return;
            }
            break;
        case OFMapFocusModeDestination:
            if (CLLocationCoordinate2DIsValid(destinationCoordinate)) {
                [self centerMapOnCoordinate:destinationCoordinate radiusMeters:42000];
                return;
            }
            break;
        case OFMapFocusModeOrigin:
            if (CLLocationCoordinate2DIsValid(originCoordinate)) {
                [self centerMapOnCoordinate:originCoordinate radiusMeters:42000];
                return;
            }
            break;
        case OFMapFocusModeRoute:
            break;
    }
    [self fitMapToPoints:points];
}

- (void)centerMapOnCoordinate:(CLLocationCoordinate2D)coordinate radiusMeters:(CLLocationDistance)radiusMeters {
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, radiusMeters, radiusMeters) animated:YES];
}

- (void)fitMapToPoints:(NSArray<NSValue *> *)points {
    if (points.count == 0) {
        return;
    }
    if (points.count == 1) {
        CLLocationCoordinate2D coordinate = [points.firstObject MKCoordinateValue];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 18000, 18000) animated:YES];
        return;
    }

    MKMapRect rect = MKMapRectNull;
    for (NSValue *value in points) {
        MKMapPoint point = MKMapPointForCoordinate([value MKCoordinateValue]);
        MKMapRect pointRect = MKMapRectMake(point.x, point.y, 1, 1);
        rect = MKMapRectIsNull(rect) ? pointRect : MKMapRectUnion(rect, pointRect);
    }
    [self.mapView setVisibleMapRect:rect edgePadding:UIEdgeInsetsMake(54, 42, 44, 42) animated:YES];
}

- (BOOL)coordinate:(CLLocationCoordinate2D *)coordinate latitude:(id)latitude longitude:(id)longitude {
    if (![latitude isKindOfClass:[NSNumber class]] || ![longitude isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    coordinate->latitude = [latitude doubleValue];
    coordinate->longitude = [longitude doubleValue];
    return CLLocationCoordinate2DIsValid(*coordinate);
}

- (BOOL)routeIsPlausible:(NSDictionary *)route forAircraft:(NSDictionary *)aircraft {
    NSDictionary *origin = [route[@"origin"] isKindOfClass:[NSDictionary class]] ? route[@"origin"] : nil;
    NSDictionary *destination = [route[@"destination"] isKindOfClass:[NSDictionary class]] ? route[@"destination"] : nil;

    CLLocationCoordinate2D originCoordinate = CLLocationCoordinate2DMake(0.0, 0.0);
    CLLocationCoordinate2D destinationCoordinate = CLLocationCoordinate2DMake(0.0, 0.0);
    CLLocationCoordinate2D planeCoordinate = CLLocationCoordinate2DMake(0.0, 0.0);
    if (![self coordinate:&originCoordinate latitude:origin[@"latitude"] longitude:origin[@"longitude"]] ||
        ![self coordinate:&destinationCoordinate latitude:destination[@"latitude"] longitude:destination[@"longitude"]] ||
        ![self coordinate:&planeCoordinate latitude:aircraft[@"lat"] longitude:aircraft[@"lon"]]) {
        return YES;
    }

    CLLocation *originLocation = [[CLLocation alloc] initWithLatitude:originCoordinate.latitude longitude:originCoordinate.longitude];
    CLLocation *destinationLocation = [[CLLocation alloc] initWithLatitude:destinationCoordinate.latitude longitude:destinationCoordinate.longitude];
    CLLocation *planeLocation = [[CLLocation alloc] initWithLatitude:planeCoordinate.latitude longitude:planeCoordinate.longitude];

    double routeLengthNM = [originLocation distanceFromLocation:destinationLocation] / 1852.0;
    double startToPlaneNM = [originLocation distanceFromLocation:planeLocation] / 1852.0;
    if (routeLengthNM <= 1.0 || startToPlaneNM <= 0.01) {
        return YES;
    }

    double routeBearing = [self initialBearingRadiansFrom:originCoordinate to:destinationCoordinate];
    double planeBearing = [self initialBearingRadiansFrom:originCoordinate to:planeCoordinate];
    double angularStartToPlane = startToPlaneNM / OFEarthRadiusNM;
    double bearingDelta = [self normalizedRadians:planeBearing - routeBearing];
    double crossTrackAngular = asin(sin(angularStartToPlane) * sin(bearingDelta));
    double crossTrackNM = fabs(crossTrackAngular * OFEarthRadiusNM);

    double alongTrackAngular = 0.0;
    double denominator = cos(crossTrackAngular);
    if (fabs(denominator) > 0.000001) {
        double ratio = cos(angularStartToPlane) / denominator;
        ratio = MIN(1.0, MAX(-1.0, ratio));
        alongTrackAngular = acos(ratio);
        if (cos(bearingDelta) < 0.0) {
            alongTrackAngular = -alongTrackAngular;
        }
    }

    double alongTrackNM = alongTrackAngular * OFEarthRadiusNM;
    double endpointDistanceNM = MIN(startToPlaneNM, [planeLocation distanceFromLocation:destinationLocation] / 1852.0);
    double allowedCrossTrackNM = MAX(100.0, MIN(300.0, routeLengthNM * 0.12));
    double allowedEndpointOvershootNM = MAX(80.0, MIN(180.0, routeLengthNM * 0.08));

    if ((alongTrackNM < -allowedEndpointOvershootNM ||
         alongTrackNM > routeLengthNM + allowedEndpointOvershootNM) &&
        endpointDistanceNM > allowedEndpointOvershootNM) {
        return NO;
    }
    return crossTrackNM <= allowedCrossTrackNM;
}

- (double)initialBearingRadiansFrom:(CLLocationCoordinate2D)start to:(CLLocationCoordinate2D)end {
    double startLatitude = [self radiansFromDegrees:start.latitude];
    double endLatitude = [self radiansFromDegrees:end.latitude];
    double longitudeDelta = [self radiansFromDegrees:end.longitude - start.longitude];
    double y = sin(longitudeDelta) * cos(endLatitude);
    double x = cos(startLatitude) * sin(endLatitude) - sin(startLatitude) * cos(endLatitude) * cos(longitudeDelta);
    return atan2(y, x);
}

- (double)radiansFromDegrees:(double)degrees {
    return degrees * M_PI / 180.0;
}

- (double)normalizedRadians:(double)radians {
    while (radians > M_PI) {
        radians -= 2.0 * M_PI;
    }
    while (radians < -M_PI) {
        radians += 2.0 * M_PI;
    }
    return radians;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
        renderer.strokeColor = [UIColor colorWithRed:0.24 green:0.88 blue:1.0 alpha:0.90];
        renderer.lineWidth = 3.5;
        renderer.lineJoin = kCGLineJoinRound;
        renderer.lineCap = kCGLineCapRound;
        return renderer;
    }
    return [[MKOverlayRenderer alloc] initWithOverlay:overlay];
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if (![annotation isKindOfClass:[FlightMapAnnotation class]]) {
        return nil;
    }
    FlightMapAnnotation *flightAnnotation = (FlightMapAnnotation *)annotation;
    NSString *identifier = flightAnnotation.kind ?: @"point";
    MKPinAnnotationView *view = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (!view) {
        view = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
        view.canShowCallout = NO;
    } else {
        view.annotation = annotation;
    }
    if ([flightAnnotation.kind isEqualToString:@"plane"]) {
        view.pinTintColor = [UIColor colorWithRed:0.20 green:0.86 blue:1.0 alpha:1.0];
        view.animatesDrop = NO;
    } else if ([flightAnnotation.kind isEqualToString:@"origin"]) {
        view.pinTintColor = [UIColor colorWithRed:0.52 green:0.82 blue:1.0 alpha:1.0];
    } else if ([flightAnnotation.kind isEqualToString:@"destination"]) {
        view.pinTintColor = [UIColor colorWithRed:1.0 green:0.74 blue:0.34 alpha:1.0];
    } else {
        view.pinTintColor = [UIColor colorWithRed:0.54 green:1.0 blue:0.64 alpha:1.0];
    }
    return view;
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    [self handleAuthorization:status];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *latest = locations.lastObject;
    if (!latest) {
        return;
    }
    self.currentLocation = latest;
    [self refreshFlights];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    self.statusLabel.text = [NSString stringWithFormat:@"Location failed: %@", error.localizedDescription];
}

- (NSString *)cleanCallsign:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

- (NSString *)stringOrNil:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    return [(NSString *)value length] > 0 ? value : nil;
}

- (NSNumber *)numberFromObject:(id)value {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

- (NSNumber *)nullableNumber:(id)value {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

- (void)setNumberFrom:(id)value key:(NSString *)key inDictionary:(NSMutableDictionary *)dictionary {
    NSNumber *number = [self nullableNumber:value];
    if (number) {
        dictionary[key] = number;
    }
}

- (NSString *)altitudeTextFromObject:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [NSString stringWithFormat:@"%.0f ft", [value doubleValue]];
    }
    return [self stringOrNil:value];
}

- (NSString *)airportCode:(NSDictionary *)airport {
    NSString *iata = [self stringOrNil:airport[@"iata_code"]];
    NSString *icao = [self stringOrNil:airport[@"icao_code"]];
    return iata ?: icao;
}

- (NSString *)airportName:(NSDictionary *)airport {
    NSString *name = [self stringOrNil:airport[@"name"]];
    NSString *municipality = [self stringOrNil:airport[@"municipality"]];
    if (name && municipality && [name rangeOfString:municipality options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return [NSString stringWithFormat:@"%@, %@", name, municipality];
    }
    return name ?: municipality;
}

@end
