#import "CCCameraListViewController.h"
#import "CCCameraDetailViewController.h"
#import "CCImageLoader.h"

static UIColor *CCListBackgroundColor(void) {
    return [UIColor colorWithRed:0.035 green:0.075 blue:0.095 alpha:1.0];
}

@interface CCCameraCell : UITableViewCell

@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, copy) NSString *representedImageURL;
- (void)configureWithCamera:(CCCamera *)camera;

@end

@implementation CCCameraCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = CCListBackgroundColor();
        self.textLabel.textColor = [UIColor colorWithWhite:0.98 alpha:1.0];
        self.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightHeavy];
        self.textLabel.numberOfLines = 2;
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.68 green:0.82 blue:0.82 alpha:1.0];
        self.detailTextLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        self.detailTextLabel.numberOfLines = 2;
        self.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds = YES;
        self.imageView.backgroundColor = [UIColor colorWithRed:0.06 green:0.13 blue:0.15 alpha:1.0];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        self.badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.badgeLabel.textAlignment = NSTextAlignmentCenter;
        self.badgeLabel.textColor = [UIColor colorWithRed:0.03 green:0.08 blue:0.09 alpha:1.0];
        self.badgeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBlack];
        self.badgeLabel.layer.cornerRadius = 4.0;
        self.badgeLabel.clipsToBounds = YES;
        [self.contentView addSubview:self.badgeLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.imageView.frame = CGRectMake(12, 10, 88, 58);
    self.imageView.layer.cornerRadius = 5.0;
    CGFloat textX = 112.0;
    CGFloat width = self.contentView.bounds.size.width - textX - 78.0;
    self.textLabel.frame = CGRectMake(textX, 9, width, 38);
    self.detailTextLabel.frame = CGRectMake(textX, 48, width, 30);
    self.badgeLabel.frame = CGRectMake(self.contentView.bounds.size.width - 72, 28, 54, 22);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
    self.representedImageURL = nil;
}

- (void)configureWithCamera:(CCCamera *)camera {
    self.textLabel.text = camera.title.length ? camera.title : @"Camera";
    NSString *city = camera.city.length ? camera.city : camera.stateName;
    self.detailTextLabel.text = [NSString stringWithFormat:@"%@ | %@", city ?: @"", camera.sourceName ?: @""];
    self.badgeLabel.text = [camera feedTypeLabel];
    self.badgeLabel.backgroundColor = camera.feedType == CCCameraFeedTypeHLS ? [UIColor colorWithRed:0.38 green:0.92 blue:0.84 alpha:1.0] : [UIColor colorWithRed:0.94 green:0.77 blue:0.38 alpha:1.0];

    self.representedImageURL = camera.imageURL;
    self.imageView.image = [self placeholderImage];
    if (camera.imageURL.length) {
        [[CCImageLoader sharedLoader] loadImageAtURL:camera.imageURL completion:^(UIImage *image) {
            if ([self.representedImageURL isEqualToString:camera.imageURL] && image) {
                self.imageView.image = image;
            }
        }];
    }
}

- (UIImage *)placeholderImage {
    CGSize size = CGSizeMake(88, 58);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    [[UIColor colorWithRed:0.06 green:0.13 blue:0.15 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    [[UIColor colorWithRed:0.25 green:0.55 blue:0.57 alpha:1.0] setStroke];
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(34, 19, 20, 20)];
    path.lineWidth = 3.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@end

@interface CCCameraListViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSArray<CCCamera *> *cameras;
@property (nonatomic, strong) UITableView *tableView;

@end

@implementation CCCameraListViewController

- (instancetype)initWithTitle:(NSString *)title cameras:(NSArray<CCCamera *> *)cameras {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.title = title;
        self.cameras = [cameras sortedArrayUsingComparator:^NSComparisonResult(CCCamera *a, CCCamera *b) {
            if (a.feedType != b.feedType) return a.feedType > b.feedType ? NSOrderedAscending : NSOrderedDescending;
            return [a.title compare:b.title options:NSCaseInsensitiveSearch];
        }] ?: @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = CCListBackgroundColor();
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = CCListBackgroundColor();
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.tableView.rowHeight = 78.0;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.cameras.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"CameraCell";
    CCCameraCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[CCCameraCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    [cell configureWithCamera:self.cameras[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CCCameraDetailViewController *controller = [[CCCameraDetailViewController alloc] initWithCamera:self.cameras[indexPath.row]];
    [self.navigationController pushViewController:controller animated:YES];
}

@end
