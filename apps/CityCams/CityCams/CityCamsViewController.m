#import "CityCamsViewController.h"
#import "CCCameraCatalog.h"
#import "CCCameraDetailViewController.h"
#import "CCCameraGroupViewController.h"
#import "CCCameraSlideshowViewController.h"
#import "CCCameraSocialFeedViewController.h"
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

static UIColor *CCBackgroundColor(void) {
    return [UIColor colorWithRed:0.035 green:0.075 blue:0.095 alpha:1.0];
}

static UIColor *CCPanelColor(void) {
    return [UIColor colorWithRed:0.075 green:0.135 blue:0.155 alpha:1.0];
}

static NSString *CCCameraSummary(NSArray<CCCamera *> *cameras) {
    NSUInteger live = 0;
    NSUInteger images = 0;
    NSMutableSet *sources = [NSMutableSet set];
    for (CCCamera *camera in cameras) {
        if (camera.feedType == CCCameraFeedTypeHLS) live++;
        if (camera.feedType == CCCameraFeedTypeImage) images++;
        if (camera.sourceIdentifier.length) [sources addObject:camera.sourceIdentifier];
    }
    return [NSString stringWithFormat:@"%lu cameras  |  %lu live  |  %lu images  |  %lu sources",
            (unsigned long)cameras.count, (unsigned long)live, (unsigned long)images, (unsigned long)sources.count];
}

@interface CCCameraAnnotation : NSObject <MKAnnotation>

@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) CCCamera *camera;

- (instancetype)initWithCamera:(CCCamera *)camera;

@end

@implementation CCCameraAnnotation

- (instancetype)initWithCamera:(CCCamera *)camera {
    self = [super init];
    if (self) {
        _coordinate = CLLocationCoordinate2DMake(camera.latitude, camera.longitude);
        _camera = camera;
        _title = camera.title.length ? camera.title : @"Camera";
        _subtitle = CCCameraSummary(@[camera]);
    }
    return self;
}

@end

@interface CityCamsViewController () <UITableViewDataSource, UITableViewDelegate, MKMapViewDelegate, CLLocationManagerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *refreshProgressTrack;
@property (nonatomic, strong) UIView *refreshProgressFill;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic) CGFloat refreshProgress;
@property (nonatomic) BOOL showingMap;
@property (nonatomic) BOOL centeredOnUserLocation;
@property (nonatomic, copy) NSArray<CCCamera *> *cameras;
@property (nonatomic, copy) NSArray<NSDictionary *> *stateRows;

@end

@implementation CityCamsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CityCams";
    self.view.backgroundColor = CCBackgroundColor();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Slideshow" style:UIBarButtonItemStylePlain target:self action:@selector(startSlideshowTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Map" style:UIBarButtonItemStylePlain target:self action:@selector(toggleMapMode)];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 186)];
    header.backgroundColor = CCPanelColor();

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, self.view.bounds.size.width - 32, 28)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLabel.text = @"Public city camera feeds";
    titleLabel.textColor = [UIColor colorWithWhite:0.98 alpha:1.0];
    titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    [header addSubview:titleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 45, self.view.bounds.size.width - 32, 34)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = [UIColor colorWithRed:0.73 green:0.87 blue:0.88 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"Loading feed catalog...";
    [header addSubview:self.statusLabel];

    UIButton *slideshowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    slideshowButton.frame = CGRectMake(16, 90, self.view.bounds.size.width - 32, 38);
    slideshowButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    slideshowButton.backgroundColor = [UIColor colorWithRed:0.10 green:0.54 blue:0.50 alpha:0.72];
    slideshowButton.layer.cornerRadius = 8.0;
    slideshowButton.layer.masksToBounds = YES;
    slideshowButton.layer.borderWidth = 1.0;
    slideshowButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [slideshowButton setTitle:@"Start Live Slideshow" forState:UIControlStateNormal];
    [slideshowButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    slideshowButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBlack];
    [slideshowButton addTarget:self action:@selector(startSlideshowTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:slideshowButton];

    UIButton *socialFeedButton = [UIButton buttonWithType:UIButtonTypeSystem];
    socialFeedButton.frame = CGRectMake(16, 134, self.view.bounds.size.width - 32, 38);
    socialFeedButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    socialFeedButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    socialFeedButton.layer.cornerRadius = 8.0;
    socialFeedButton.layer.masksToBounds = YES;
    socialFeedButton.layer.borderWidth = 1.0;
    socialFeedButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [socialFeedButton setTitle:@"Open Social Feed" forState:UIControlStateNormal];
    [socialFeedButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    socialFeedButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBlack];
    [socialFeedButton addTarget:self action:@selector(startSocialFeedTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:socialFeedButton];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = CCBackgroundColor();
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.tableView.tableHeaderView = header;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.tableView.rowHeight = 74.0;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    self.mapView = [[MKMapView alloc] initWithFrame:self.view.bounds];
    self.mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mapView.delegate = self;
    self.mapView.showsUserLocation = YES;
    self.mapView.hidden = YES;
    [self.view addSubview:self.mapView];

    self.refreshProgressTrack = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 3)];
    self.refreshProgressTrack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.refreshProgressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.refreshProgressTrack.hidden = YES;
    self.refreshProgressTrack.alpha = 0.0;
    [self.view addSubview:self.refreshProgressTrack];

    self.refreshProgressFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 3)];
    self.refreshProgressFill.backgroundColor = [UIColor colorWithRed:0.25 green:0.86 blue:0.78 alpha:1.0];
    [self.refreshProgressTrack addSubview:self.refreshProgressFill];

    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyKilometer;

    NSArray *cached = [[CCCameraCatalog sharedCatalog] loadCachedCameras];
    [self updateWithCameras:cached status:[self launchStatusText]];
    __weak typeof(self) weakSelf = self;
    [[CCCameraCatalog sharedCatalog] refreshInBackgroundIfNeededWithProgress:^(NSUInteger completedProviders, NSUInteger totalProviders, NSString *providerName) {
        [weakSelf updateRefreshProgressCompleted:completedProviders total:totalProviders providerName:providerName];
    } completion:^(NSArray<CCCamera *> *cameras, NSString *statusText) {
        [weakSelf setRefreshProgressVisible:NO animated:YES];
        [weakSelf updateWithCameras:cameras status:statusText];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutRefreshProgressFill];
}

- (NSString *)launchStatusText {
    CCCameraCatalog *catalog = [CCCameraCatalog sharedCatalog];
    if (catalog.cameras.count == 0) return @"Daily feed refresh will run quietly in the background.";
    if ([catalog needsRefresh]) return @"Loaded cached feeds. Daily background refresh is queued.";
    return @"Loaded cached feeds. Daily refresh is current.";
}

- (void)updateWithCameras:(NSArray<CCCamera *> *)cameras status:(NSString *)status {
    self.cameras = cameras ?: @[];
    self.stateRows = [self rowsGroupedByState:self.cameras];
    self.statusLabel.text = status.length ? status : CCCameraSummary(self.cameras);
    [self.tableView reloadData];
    [self reloadMapAnnotations];
}

- (void)updateRefreshProgressCompleted:(NSUInteger)completedProviders total:(NSUInteger)totalProviders providerName:(NSString *)providerName {
    if (totalProviders == 0) return;
    self.refreshProgress = MIN(1.0, MAX(0.03, (CGFloat)completedProviders / (CGFloat)totalProviders));
    [self setRefreshProgressVisible:YES animated:YES];
    [UIView animateWithDuration:0.18 animations:^{
        [self layoutRefreshProgressFill];
    }];
    if (completedProviders == 0) {
        self.statusLabel.text = @"Refreshing camera catalog in the background...";
    } else {
        NSString *source = providerName.length ? providerName : @"source";
        self.statusLabel.text = [NSString stringWithFormat:@"Refreshing: %lu of %lu sources  |  %@",
                                 (unsigned long)completedProviders, (unsigned long)totalProviders, source];
    }
}

- (void)setRefreshProgressVisible:(BOOL)visible animated:(BOOL)animated {
    if (visible) {
        self.refreshProgressTrack.hidden = NO;
    }
    CGFloat alpha = visible ? 1.0 : 0.0;
    void (^changes)(void) = ^{
        self.refreshProgressTrack.alpha = alpha;
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        if (!visible) {
            self.refreshProgress = 0;
            [self layoutRefreshProgressFill];
            self.refreshProgressTrack.hidden = YES;
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

- (void)layoutRefreshProgressFill {
    CGFloat width = self.refreshProgressTrack.bounds.size.width * self.refreshProgress;
    self.refreshProgressFill.frame = CGRectMake(0, 0, width, self.refreshProgressTrack.bounds.size.height);
}

- (void)toggleMapMode {
    self.showingMap = !self.showingMap;
    self.tableView.hidden = self.showingMap;
    self.mapView.hidden = !self.showingMap;
    self.navigationItem.rightBarButtonItem.title = self.showingMap ? @"List" : @"Map";
    if (self.showingMap) {
        [self reloadMapAnnotations];
        [self startLocationCenteringIfNeeded];
        if (!self.centeredOnUserLocation) {
            [self fitMapToCameraAnnotations];
        }
    }
}

- (void)startSlideshowTapped {
    NSMutableArray *live = [NSMutableArray array];
    for (CCCamera *camera in self.cameras) {
        if ([camera hasPlayableStream]) [live addObject:camera];
    }
    if (live.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No live streams yet" message:@"CityCams needs at least one cached HLS camera before slideshow can start. Let the daily refresh finish, then try again." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    CCCameraSlideshowViewController *controller = [[CCCameraSlideshowViewController alloc] initWithCameras:live];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)startSocialFeedTapped {
    if (self.cameras.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No cameras yet" message:@"Let the camera catalog load, then try the social feed again." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    CCCameraSocialFeedViewController *controller = [[CCCameraSocialFeedViewController alloc] initWithCameras:self.cameras];
    [self.navigationController pushViewController:controller animated:YES];
}

- (NSArray<CCCamera *> *)mappableCameras {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(CCCamera *camera, NSDictionary *bindings) {
        return camera.latitude != 0 || camera.longitude != 0;
    }];
    return [self.cameras filteredArrayUsingPredicate:predicate];
}

- (void)reloadMapAnnotations {
    if (!self.mapView) return;
    NSMutableArray *oldAnnotations = [NSMutableArray array];
    for (id<MKAnnotation> annotation in self.mapView.annotations) {
        if (annotation != self.mapView.userLocation) [oldAnnotations addObject:annotation];
    }
    [self.mapView removeAnnotations:oldAnnotations];
    NSMutableArray *annotations = [NSMutableArray array];
    for (CCCamera *camera in [self mappableCameras]) {
        [annotations addObject:[[CCCameraAnnotation alloc] initWithCamera:camera]];
    }
    [self.mapView addAnnotations:annotations];
}

- (void)startLocationCenteringIfNeeded {
    CLAuthorizationStatus status = [CLLocationManager authorizationStatus];
    if (status == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
        return;
    }
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        [self.locationManager startUpdatingLocation];
    }
}

- (void)fitMapToCameraAnnotations {
    NSArray<CCCamera *> *mappable = [self mappableCameras];
    if (mappable.count == 0) return;
    double minLat = 90.0;
    double maxLat = -90.0;
    double minLon = 180.0;
    double maxLon = -180.0;
    for (CCCamera *camera in mappable) {
        minLat = MIN(minLat, camera.latitude);
        maxLat = MAX(maxLat, camera.latitude);
        minLon = MIN(minLon, camera.longitude);
        maxLon = MAX(maxLon, camera.longitude);
    }
    CLLocationCoordinate2D center = CLLocationCoordinate2DMake((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0);
    MKCoordinateSpan span = MKCoordinateSpanMake(MAX(0.25, (maxLat - minLat) * 1.25), MAX(0.25, (maxLon - minLon) * 1.25));
    [self.mapView setRegion:MKCoordinateRegionMake(center, span) animated:NO];
}

- (NSArray<NSDictionary *> *)rowsGroupedByState:(NSArray<CCCamera *> *)cameras {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (CCCamera *camera in cameras) {
        NSString *key = camera.stateCode.length ? camera.stateCode : @"--";
        NSMutableArray *bucket = groups[key];
        if (!bucket) {
            bucket = [NSMutableArray array];
            groups[key] = bucket;
        }
        [bucket addObject:camera];
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *state in [CCCameraCatalog allStates]) {
        NSString *key = state[@"code"];
        NSArray *bucket = groups[key] ?: @[];
        [rows addObject:@{@"key": key, @"title": state[@"name"], @"cameras": bucket}];
    }
    return rows;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.stateRows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"StateCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.backgroundColor = CCBackgroundColor();
        cell.textLabel.textColor = [UIColor colorWithWhite:0.98 alpha:1.0];
        cell.textLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.71 green:0.83 blue:0.84 alpha:1.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *row = self.stateRows[indexPath.row];
    NSArray *cameras = row[@"cameras"];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = cameras.count ? CCCameraSummary(cameras) : @"No public feed adapter wired yet";
    cell.accessoryType = cameras.count ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.stateRows[indexPath.row];
    if ([row[@"cameras"] count] == 0) return;
    CCCameraGroupViewController *controller = [[CCCameraGroupViewController alloc] initWithTitle:row[@"title"] cameras:row[@"cameras"] mode:CCCameraGroupModeCity];
    [self.navigationController pushViewController:controller animated:YES];
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if (annotation == mapView.userLocation) return nil;
    static NSString *identifier = @"CameraPin";
    MKPinAnnotationView *view = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (!view) {
        view = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
        view.canShowCallout = YES;
        view.animatesDrop = NO;
        view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        view.pinTintColor = [UIColor colorWithRed:0.03 green:0.50 blue:0.46 alpha:1.0];
    } else {
        view.annotation = annotation;
    }
    return view;
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view calloutAccessoryControlTapped:(UIControl *)control {
    if (![view.annotation isKindOfClass:[CCCameraAnnotation class]]) return;
    CCCameraAnnotation *annotation = (CCCameraAnnotation *)view.annotation;
    CCCameraDetailViewController *controller = [[CCCameraDetailViewController alloc] initWithCamera:annotation.camera];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view {
    if (view.annotation == mapView.userLocation) return;
    if (![view.annotation isKindOfClass:[CCCameraAnnotation class]]) return;
    if (view.canShowCallout) return;
    CCCameraAnnotation *annotation = (CCCameraAnnotation *)view.annotation;
    CCCameraDetailViewController *controller = [[CCCameraDetailViewController alloc] initWithCamera:annotation.camera];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if (!self.showingMap) return;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        [manager startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (!location) return;
    self.centeredOnUserLocation = YES;
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(location.coordinate, 50000.0, 50000.0);
    [self.mapView setRegion:region animated:YES];
    [manager stopUpdatingLocation];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    [self fitMapToCameraAnnotations];
}

@end
