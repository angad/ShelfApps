#import "CCCameraSocialFeedViewController.h"
#import "CCCameraDetailViewController.h"
#import "CCCameraStoryViewController.h"
#import "CCImageLoader.h"

static UIColor *CCSocialWhite(void) {
    return [UIColor colorWithWhite:1.0 alpha:1.0];
}

static UIColor *CCSocialText(void) {
    return [UIColor colorWithWhite:0.05 alpha:1.0];
}

@interface CCSocialAccount : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *stateCode;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSArray<CCCamera *> *cameras;

@end

@implementation CCSocialAccount
@end

static NSArray *CCShuffleArray(NSArray *array) {
    NSMutableArray *items = [array mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = items.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [items exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
    return items;
}

static NSString *CCInitialsForAccount(CCSocialAccount *account) {
    NSMutableString *initials = [NSMutableString string];
    NSArray *words = [account.title componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *word in words) {
        if (word.length == 0) continue;
        [initials appendString:[[word substringToIndex:1] uppercaseString]];
        if (initials.length >= 2) break;
    }
    return initials.length ? initials : @"CC";
}

static UIImage *CCFlagImageForStateCode(NSString *stateCode) {
    if (stateCode.length == 0) return nil;
    NSString *normalized = [[stateCode uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *assetName = [NSString stringWithFormat:@"StateFlag_%@", normalized];
    UIImage *image = [UIImage imageNamed:assetName];
    if (!image) {
        image = [UIImage imageNamed:[NSString stringWithFormat:@"StateFlags/%@.png", assetName]];
    }
    return image;
}

@interface CCStoryCell : UICollectionViewCell

@property (nonatomic, strong) UIView *ringView;
@property (nonatomic, strong) UIImageView *avatarImageView;
@property (nonatomic, strong) UILabel *avatarLabel;
@property (nonatomic, strong) UILabel *titleLabel;
- (void)configureWithAccount:(CCSocialAccount *)account;

@end

@implementation CCStoryCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        self.ringView = [[UIView alloc] initWithFrame:CGRectZero];
        self.ringView.backgroundColor = [UIColor colorWithRed:0.94 green:0.20 blue:0.43 alpha:1.0];
        self.ringView.layer.cornerRadius = 31.0;
        [self.contentView addSubview:self.ringView];

        self.avatarImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.avatarImageView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:1.0];
        self.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarImageView.clipsToBounds = YES;
        self.avatarImageView.layer.cornerRadius = 27.0;
        self.avatarImageView.layer.borderColor = [UIColor whiteColor].CGColor;
        self.avatarImageView.layer.borderWidth = 2.0;
        [self.contentView addSubview:self.avatarImageView];

        self.avatarLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.avatarLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:1.0];
        self.avatarLabel.textColor = CCSocialText();
        self.avatarLabel.textAlignment = NSTextAlignmentCenter;
        self.avatarLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBlack];
        self.avatarLabel.layer.cornerRadius = 27.0;
        self.avatarLabel.layer.masksToBounds = YES;
        self.avatarLabel.layer.borderColor = [UIColor whiteColor].CGColor;
        self.avatarLabel.layer.borderWidth = 2.0;
        [self.contentView addSubview:self.avatarLabel];

        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.titleLabel.textColor = CCSocialText();
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:self.titleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat centerX = self.contentView.bounds.size.width / 2.0;
    self.ringView.frame = CGRectMake(centerX - 31, 4, 62, 62);
    self.ringView.layer.cornerRadius = 31.0;
    self.avatarImageView.frame = CGRectMake(centerX - 27, 8, 54, 54);
    self.avatarImageView.layer.cornerRadius = 27.0;
    self.avatarLabel.frame = CGRectMake(centerX - 27, 8, 54, 54);
    self.avatarLabel.layer.cornerRadius = 27.0;
    self.titleLabel.frame = CGRectMake(1, 70, self.contentView.bounds.size.width - 2, 18);
}

- (void)configureWithAccount:(CCSocialAccount *)account {
    UIImage *flag = CCFlagImageForStateCode(account.stateCode);
    self.avatarImageView.image = flag;
    self.avatarImageView.hidden = flag == nil;
    self.avatarLabel.hidden = flag != nil;
    self.avatarLabel.text = CCInitialsForAccount(account);
    self.titleLabel.text = account.title.length ? account.title : @"Cameras";
}

@end

@interface CCPostCell : UITableViewCell

@property (nonatomic, strong) UILabel *avatarLabel;
@property (nonatomic, strong) UIImageView *avatarImageView;
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UIImageView *cameraImageView;
@property (nonatomic, strong) UILabel *liveBadgeLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, copy) NSString *representedImageURL;
- (void)configureWithCamera:(CCCamera *)camera account:(CCSocialAccount *)account;

@end

@implementation CCPostCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = CCSocialWhite();
        self.contentView.backgroundColor = CCSocialWhite();

        self.avatarImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarImageView.clipsToBounds = YES;
        self.avatarImageView.layer.borderColor = [UIColor colorWithWhite:0.1 alpha:1.0].CGColor;
        self.avatarImageView.layer.borderWidth = 1.0;
        self.avatarImageView.layer.masksToBounds = YES;
        [self.contentView addSubview:self.avatarImageView];

        self.avatarLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.avatarLabel.textAlignment = NSTextAlignmentCenter;
        self.avatarLabel.textColor = CCSocialText();
        self.avatarLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBlack];
        self.avatarLabel.layer.borderColor = [UIColor colorWithWhite:0.1 alpha:1.0].CGColor;
        self.avatarLabel.layer.borderWidth = 1.0;
        self.avatarLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.avatarLabel];

        self.accountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.accountLabel.textColor = CCSocialText();
        self.accountLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBlack];
        [self.contentView addSubview:self.accountLabel];

        self.sourceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.sourceLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
        self.sourceLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        [self.contentView addSubview:self.sourceLabel];

        self.cameraImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.cameraImageView.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        self.cameraImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.cameraImageView.clipsToBounds = YES;
        [self.contentView addSubview:self.cameraImageView];

        self.liveBadgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.liveBadgeLabel.backgroundColor = [UIColor colorWithRed:0.95 green:0.08 blue:0.22 alpha:0.94];
        self.liveBadgeLabel.textColor = [UIColor whiteColor];
        self.liveBadgeLabel.textAlignment = NSTextAlignmentCenter;
        self.liveBadgeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBlack];
        self.liveBadgeLabel.layer.cornerRadius = 4.0;
        self.liveBadgeLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.liveBadgeLabel];

        self.captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.captionLabel.textColor = CCSocialText();
        self.captionLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        self.captionLabel.numberOfLines = 2;
        [self.contentView addSubview:self.captionLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedImageURL = nil;
    self.cameraImageView.image = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    self.avatarImageView.frame = CGRectMake(12, 10, 34, 34);
    self.avatarImageView.layer.cornerRadius = 17.0;
    self.avatarLabel.frame = CGRectMake(12, 10, 34, 34);
    self.avatarLabel.layer.cornerRadius = 17.0;
    self.accountLabel.frame = CGRectMake(54, 8, width - 70, 20);
    self.sourceLabel.frame = CGRectMake(54, 28, width - 70, 16);
    CGFloat imageY = 52.0;
    CGFloat imageHeight = width * 0.72;
    self.cameraImageView.frame = CGRectMake(0, imageY, width, imageHeight);
    self.liveBadgeLabel.frame = CGRectMake(12, imageY + 12, 50, 22);
    self.captionLabel.frame = CGRectMake(12, imageY + imageHeight + 12, width - 24, 38);
}

- (void)configureWithCamera:(CCCamera *)camera account:(CCSocialAccount *)account {
    UIImage *flag = CCFlagImageForStateCode(account.stateCode.length ? account.stateCode : camera.stateCode);
    self.avatarImageView.image = flag;
    self.avatarImageView.hidden = flag == nil;
    self.avatarLabel.hidden = flag != nil;
    self.avatarLabel.text = CCInitialsForAccount(account);
    self.accountLabel.text = account.title.length ? account.title : camera.stateName;
    self.sourceLabel.text = account.subtitle.length ? account.subtitle : camera.sourceName;
    self.liveBadgeLabel.text = camera.feedType == CCCameraFeedTypeHLS ? @"LIVE" : @"IMAGE";
    self.liveBadgeLabel.backgroundColor = camera.feedType == CCCameraFeedTypeHLS ? [UIColor colorWithRed:0.95 green:0.08 blue:0.22 alpha:0.94] : [UIColor colorWithWhite:0.05 alpha:0.78];
    NSString *place = camera.city.length ? camera.city : camera.stateName;
    NSString *title = camera.title.length ? camera.title : @"Camera";
    self.captionLabel.text = [NSString stringWithFormat:@"%@  %@", place ?: @"", title];

    self.representedImageURL = camera.imageURL;
    self.cameraImageView.image = [self placeholderImageWithText:camera.stateCode.length ? camera.stateCode : @"CC"];
    if (camera.imageURL.length) {
        [[CCImageLoader sharedLoader] loadImageAtURL:camera.imageURL completion:^(UIImage *image) {
            if ([self.representedImageURL isEqualToString:camera.imageURL] && image) {
                self.cameraImageView.image = image;
            }
        }];
    }
}

- (UIImage *)placeholderImageWithText:(NSString *)text {
    CGSize size = CGSizeMake(320, 230);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    [[UIColor colorWithWhite:0.94 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:42 weight:UIFontWeightBlack],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.25 alpha:1.0]
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    [text drawAtPoint:CGPointMake((size.width - textSize.width) / 2.0, (size.height - textSize.height) / 2.0) withAttributes:attributes];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@end

@interface CCCameraSocialFeedViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSArray<CCCamera *> *posts;
@property (nonatomic, copy) NSArray<CCSocialAccount *> *accounts;
@property (nonatomic, strong) UICollectionView *storiesView;
@property (nonatomic, strong) UITableView *tableView;

@end

@implementation CCCameraSocialFeedViewController

- (instancetype)initWithCameras:(NSArray<CCCamera *> *)cameras {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        NSArray *usable = [self camerasWithMedia:cameras ?: @[]];
        _posts = CCShuffleArray(usable);
        _accounts = [self randomAccountsFromCameras:usable];
        self.title = @"CityCams";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = CCSocialWhite();
    [self buildInterface];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.barTintColor = CCSocialWhite();
    self.navigationController.navigationBar.tintColor = CCSocialText();
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: CCSocialText(),
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBar.barTintColor = [UIColor colorWithRed:0.04 green:0.10 blue:0.13 alpha:1.0];
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:0.36 green:0.86 blue:0.84 alpha:1.0];
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.98 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };
}

- (NSArray<CCCamera *> *)camerasWithMedia:(NSArray<CCCamera *> *)cameras {
    NSMutableArray *usable = [NSMutableArray array];
    for (CCCamera *camera in cameras) {
        if (camera.imageURL.length || [camera hasPlayableStream]) [usable addObject:camera];
    }
    return usable;
}

- (NSArray<CCSocialAccount *> *)randomAccountsFromCameras:(NSArray<CCCamera *> *)cameras {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (CCCamera *camera in cameras) {
        NSString *state = camera.stateName.length ? camera.stateName : (camera.stateCode ?: @"State");
        NSString *source = camera.sourceName.length ? camera.sourceName : @"Source";
        NSString *key = [NSString stringWithFormat:@"%@|%@", state, source];
        NSMutableArray *bucket = groups[key];
        if (!bucket) {
            bucket = [NSMutableArray array];
            groups[key] = bucket;
        }
        [bucket addObject:camera];
    }
    NSMutableArray *accounts = [NSMutableArray array];
    for (NSString *key in groups) {
        NSArray<CCCamera *> *bucket = groups[key];
        CCCamera *camera = bucket.firstObject;
        CCSocialAccount *account = [[CCSocialAccount alloc] init];
        account.identifier = key;
        account.stateCode = camera.stateCode;
        account.title = camera.stateName.length ? camera.stateName : camera.stateCode;
        account.subtitle = camera.sourceName.length ? camera.sourceName : @"Public cameras";
        account.cameras = CCShuffleArray(bucket);
        [accounts addObject:account];
    }
    return CCShuffleArray(accounts);
}

- (void)buildInterface {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize = CGSizeMake(78, 92);
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsMake(0, 8, 0, 8);

    self.storiesView = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 98) collectionViewLayout:layout];
    self.storiesView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.storiesView.backgroundColor = CCSocialWhite();
    self.storiesView.showsHorizontalScrollIndicator = NO;
    self.storiesView.dataSource = self;
    self.storiesView.delegate = self;
    [self.storiesView registerClass:[CCStoryCell class] forCellWithReuseIdentifier:@"StoryCell"];
    [self.view addSubview:self.storiesView];

    UIView *storyRule = [[UIView alloc] initWithFrame:CGRectMake(0, 97, self.view.bounds.size.width, 1)];
    storyRule.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    storyRule.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    [self.view addSubview:storyRule];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 98, self.view.bounds.size.width, self.view.bounds.size.height - 98) style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = CCSocialWhite();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.tableView];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.accounts.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    CCStoryCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"StoryCell" forIndexPath:indexPath];
    [cell configureWithAccount:self.accounts[indexPath.item]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    CCSocialAccount *account = self.accounts[indexPath.item];
    CCCameraStoryViewController *controller = [[CCCameraStoryViewController alloc] initWithCameras:account.cameras accountTitle:account.title accountSubtitle:account.subtitle];
    [self presentViewController:controller animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.posts.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.bounds.size.width * 0.72 + 104.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"PostCell";
    CCPostCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[CCPostCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    CCCamera *camera = self.posts[indexPath.row];
    [cell configureWithCamera:camera account:[self accountForCamera:camera]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CCCameraDetailViewController *controller = [[CCCameraDetailViewController alloc] initWithCamera:self.posts[indexPath.row]];
    [self.navigationController pushViewController:controller animated:YES];
}

- (CCSocialAccount *)accountForCamera:(CCCamera *)camera {
    NSString *state = camera.stateName.length ? camera.stateName : (camera.stateCode ?: @"State");
    NSString *source = camera.sourceName.length ? camera.sourceName : @"Source";
    NSString *key = [NSString stringWithFormat:@"%@|%@", state, source];
    for (CCSocialAccount *account in self.accounts) {
        if ([account.identifier isEqualToString:key]) return account;
    }
    CCSocialAccount *fallback = [[CCSocialAccount alloc] init];
    fallback.stateCode = camera.stateCode;
    fallback.title = state;
    fallback.subtitle = source;
    fallback.cameras = @[camera];
    return fallback;
}

@end
