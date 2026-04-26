#import "CCCameraGroupViewController.h"
#import "CCCameraListViewController.h"

static UIColor *CCGroupBackgroundColor(void) {
    return [UIColor colorWithRed:0.035 green:0.075 blue:0.095 alpha:1.0];
}

static NSString *CCGroupSummary(NSArray<CCCamera *> *cameras) {
    NSUInteger live = 0;
    NSUInteger images = 0;
    for (CCCamera *camera in cameras) {
        if (camera.feedType == CCCameraFeedTypeHLS) live++;
        if (camera.feedType == CCCameraFeedTypeImage) images++;
    }
    return [NSString stringWithFormat:@"%lu cameras  |  %lu live  |  %lu images",
            (unsigned long)cameras.count, (unsigned long)live, (unsigned long)images];
}

@interface CCCameraGroupViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSArray<CCCamera *> *cameras;
@property (nonatomic) CCCameraGroupMode mode;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;

@end

@implementation CCCameraGroupViewController

- (instancetype)initWithTitle:(NSString *)title cameras:(NSArray<CCCamera *> *)cameras mode:(CCCameraGroupMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.title = title;
        self.cameras = cameras ?: @[];
        self.mode = mode;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = CCGroupBackgroundColor();
    self.rows = [self groupedRows];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = CCGroupBackgroundColor();
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.tableView.rowHeight = 70.0;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
}

- (NSArray<NSDictionary *> *)groupedRows {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (CCCamera *camera in self.cameras) {
        NSString *key = self.mode == CCCameraGroupModeCity ? camera.city : camera.sourceName;
        if (key.length == 0) key = @"Unknown";
        NSMutableArray *bucket = groups[key];
        if (!bucket) {
            bucket = [NSMutableArray array];
            groups[key] = bucket;
        }
        [bucket addObject:camera];
    }

    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *key in groups) {
        [rows addObject:@{@"title": key, @"cameras": groups[key]}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSArray *left = a[@"cameras"];
        NSArray *right = b[@"cameras"];
        if (left.count != right.count) {
            return left.count > right.count ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a[@"title"] compare:b[@"title"] options:NSCaseInsensitiveSearch];
    }];
    return rows;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"GroupCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.backgroundColor = CCGroupBackgroundColor();
        cell.textLabel.textColor = [UIColor colorWithWhite:0.98 alpha:1.0];
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightHeavy];
        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.70 green:0.84 blue:0.84 alpha:1.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *row = self.rows[indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = CCGroupSummary(row[@"cameras"]);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.rows[indexPath.row];
    NSArray *cameras = row[@"cameras"];
    if (self.mode == CCCameraGroupModeCity) {
        CCCameraGroupViewController *controller = [[CCCameraGroupViewController alloc] initWithTitle:row[@"title"] cameras:cameras mode:CCCameraGroupModeSource];
        [self.navigationController pushViewController:controller animated:YES];
    } else {
        CCCameraListViewController *controller = [[CCCameraListViewController alloc] initWithTitle:row[@"title"] cameras:cameras];
        [self.navigationController pushViewController:controller animated:YES];
    }
}

@end
