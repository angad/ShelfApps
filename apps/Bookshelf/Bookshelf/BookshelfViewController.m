#import "BookshelfViewController.h"
#import "BKCoverView.h"
#import "BKGoodreadsClient.h"
#import "BKLibraryStore.h"
#import "BKResalePriceClient.h"
#import "BookDetailsViewController.h"
#import "ScannerViewController.h"

static NSString * const BKBookCellIdentifier = @"BKBookCell";

@interface BKBookCell : UITableViewCell

@property (nonatomic, strong) BKCoverView *coverViewSmall;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *ratingLabel;
@property (nonatomic, strong) UILabel *priceLabel;

- (void)configureWithBook:(BKBook *)book;

@end

@implementation BKBookCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor colorWithRed:0.19 green:0.13 blue:0.09 alpha:1.0];
        self.contentView.layer.cornerRadius = 7.0;
        self.contentView.layer.masksToBounds = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.coverViewSmall = [[BKCoverView alloc] initWithFrame:CGRectZero];
        self.coverViewSmall.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.coverViewSmall];

        self.titleLabel = [BKBookCell labelWithSize:15.0 weight:UIFontWeightBold color:[UIColor colorWithRed:0.97 green:0.91 blue:0.82 alpha:1.0]];
        self.titleLabel.numberOfLines = 2;
        self.authorLabel = [BKBookCell labelWithSize:12.0 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.79 green:0.70 blue:0.58 alpha:1.0]];
        self.metaLabel = [BKBookCell labelWithSize:11.0 weight:UIFontWeightRegular color:[UIColor colorWithRed:0.68 green:0.58 blue:0.45 alpha:1.0]];
        self.statusLabel = [BKBookCell labelWithSize:10.0 weight:UIFontWeightBold color:[UIColor colorWithRed:0.20 green:0.13 blue:0.08 alpha:1.0]];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        self.statusLabel.backgroundColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
        self.statusLabel.layer.cornerRadius = 4.0;
        self.statusLabel.layer.masksToBounds = YES;
        self.ratingLabel = [BKBookCell labelWithSize:11.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0]];
        self.ratingLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:self.ratingLabel];
        self.priceLabel = [BKBookCell labelWithSize:10.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.68 green:0.82 blue:0.60 alpha:1.0]];
        self.priceLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:self.priceLabel];

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.authorLabel, self.metaLabel]];
        textStack.translatesAutoresizingMaskIntoConstraints = NO;
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 3.0;
        [self.contentView addSubview:textStack];
        [self.contentView addSubview:self.statusLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.coverViewSmall.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10.0],
            [self.coverViewSmall.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.coverViewSmall.widthAnchor constraintEqualToConstant:46.0],
            [self.coverViewSmall.heightAnchor constraintEqualToConstant:68.0],

            [textStack.leadingAnchor constraintEqualToAnchor:self.coverViewSmall.trailingAnchor constant:12.0],
            [textStack.trailingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor constant:-8.0],
            [textStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

            [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10.0],
            [self.statusLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],
            [self.statusLabel.widthAnchor constraintEqualToConstant:52.0],
            [self.statusLabel.heightAnchor constraintEqualToConstant:22.0],

            [self.ratingLabel.trailingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor],
            [self.ratingLabel.leadingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor],
            [self.ratingLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8.0],
            [self.ratingLabel.heightAnchor constraintEqualToConstant:16.0],

            [self.priceLabel.trailingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor],
            [self.priceLabel.leadingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor],
            [self.priceLabel.topAnchor constraintEqualToAnchor:self.ratingLabel.bottomAnchor constant:1.0],
            [self.priceLabel.heightAnchor constraintEqualToConstant:15.0]
        ]];
    }
    return self;
}

+ (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.contentView.frame = UIEdgeInsetsInsetRect(self.contentView.frame, UIEdgeInsetsMake(4.0, 10.0, 4.0, 10.0));
}

- (void)configureWithBook:(BKBook *)book {
    [self.coverViewSmall configureWithBook:book compact:YES];
    self.titleLabel.text = book.title;
    self.authorLabel.text = book.author;
    if ([[book.status lowercaseString] isEqualToString:@"loaned"] && book.borrowerName.length > 0) {
        self.metaLabel.text = [NSString stringWithFormat:@"Loaned to %@  •  %@", book.borrowerName, book.shelf.length ? book.shelf : @"Main shelf"];
    } else {
        self.metaLabel.text = [NSString stringWithFormat:@"%@  •  %@", book.shelf.length ? book.shelf : @"Main shelf", book.conditionText.length ? book.conditionText : @"Good"];
    }
    self.statusLabel.text = [book.status uppercaseString];
    self.ratingLabel.text = book.goodreadsAverageRating.length ? [NSString stringWithFormat:@"GR %@", book.goodreadsAverageRating] : @"";
    self.priceLabel.text = [BKResalePriceClient isPricingModeEnabled] ? (book.resalePrice.length ? book.resalePrice : @"$ --") : @"";
}

@end

@interface BookshelfViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, ScannerViewControllerDelegate>

@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIButton *pricingButton;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<BKBook *> *visibleBooks;

@end

@implementation BookshelfViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Bookshelf";
    self.view.backgroundColor = [UIColor colorWithRed:0.12 green:0.08 blue:0.055 alpha:1.0];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addTapped)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit target:self action:@selector(editTapped)];

    [self buildInterface];
    [self reloadBooks];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadBooks];
}

- (void)buildInterface {
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    UILabel *eyebrow = [self labelWithText:@"PERSONAL LIBRARY" size:11.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0]];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:eyebrow];

    self.countLabel = [self labelWithText:@"" size:13.0 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.79 green:0.70 blue:0.58 alpha:1.0]];
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.textAlignment = NSTextAlignmentRight;
    [header addSubview:self.countLabel];

    self.pricingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.pricingButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.pricingButton.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBlack];
    self.pricingButton.layer.cornerRadius = 4.0;
    self.pricingButton.layer.masksToBounds = YES;
    [self.pricingButton addTarget:self action:@selector(pricingTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.pricingButton];
    [self updatePricingButton];

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Unread", @"Loaned"]];
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterControl.selectedSegmentIndex = 0;
    self.filterControl.tintColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
    [self.filterControl addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:self.filterControl];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search title, author, ISBN";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.tintColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
    [header addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 92.0;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [self.tableView registerClass:[BKBookCell class] forCellReuseIdentifier:BKBookCellIdentifier];
    [self.view addSubview:self.tableView];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [header.heightAnchor constraintEqualToConstant:118.0],

        [eyebrow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [eyebrow.topAnchor constraintEqualToAnchor:header.topAnchor constant:12.0],
        [eyebrow.trailingAnchor constraintLessThanOrEqualToAnchor:self.pricingButton.leadingAnchor constant:-8.0],

        [self.countLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:eyebrow.centerYAnchor],

        [self.pricingButton.trailingAnchor constraintEqualToAnchor:self.countLabel.leadingAnchor constant:-8.0],
        [self.pricingButton.centerYAnchor constraintEqualToAnchor:self.countLabel.centerYAnchor],
        [self.pricingButton.widthAnchor constraintEqualToConstant:62.0],
        [self.pricingButton.heightAnchor constraintEqualToConstant:20.0],

        [self.filterControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [self.filterControl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [self.filterControl.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:10.0],
        [self.filterControl.heightAnchor constraintEqualToConstant:29.0],

        [self.searchBar.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:8.0],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8.0],
        [self.searchBar.topAnchor constraintEqualToAnchor:self.filterControl.bottomAnchor constant:6.0],
        [self.searchBar.heightAnchor constraintEqualToConstant:44.0],

        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)reloadBooks {
    NSArray<BKBook *> *allBooks = [[BKLibraryStore sharedStore] books];
    NSString *query = [self.searchBar.text lowercaseString] ?: @"";
    NSMutableArray *filtered = [NSMutableArray array];
    for (BKBook *book in allBooks) {
        BOOL matchesFilter = YES;
        if (self.filterControl.selectedSegmentIndex == 1) {
            matchesFilter = ![[book.status lowercaseString] isEqualToString:@"read"];
        } else if (self.filterControl.selectedSegmentIndex == 2) {
            matchesFilter = [[book.status lowercaseString] isEqualToString:@"loaned"];
        }

        BOOL matchesSearch = query.length == 0 ||
            [[book.title lowercaseString] containsString:query] ||
            [[book.author lowercaseString] containsString:query] ||
            [[book.isbn lowercaseString] containsString:query];

        if (matchesFilter && matchesSearch) {
            [filtered addObject:book];
        }
    }
    self.visibleBooks = filtered;
    self.countLabel.text = [NSString stringWithFormat:@"%lu books", (unsigned long)allBooks.count];
    [self.tableView reloadData];
    [self enrichBooksIfNeeded:allBooks];
    [self refreshResalePricesIfNeeded:allBooks force:NO];
}

- (void)enrichBooksIfNeeded:(NSArray<BKBook *> *)books {
    for (BKBook *book in books) {
        if (book.isbn.length == 0 || (book.goodreadsAverageRating.length > 0 && book.coverImageURL.length > 0)) {
            continue;
        }
        [[BKGoodreadsClient sharedClient] enrichBook:book completion:^(BOOL changed) {
            if (changed) {
                [[BKLibraryStore sharedStore] updateBook:book];
                [self reloadBooks];
            }
        }];
    }
}

- (void)refreshResalePricesIfNeeded:(NSArray<BKBook *> *)books force:(BOOL)force {
    if (![BKResalePriceClient isPricingModeEnabled]) {
        return;
    }
    for (BKBook *book in books) {
        [[BKResalePriceClient sharedClient] refreshBookIfNeeded:book force:force completion:^(BOOL changed) {
            if (changed) {
                [[BKLibraryStore sharedStore] updateBook:book];
                [self reloadBooks];
            }
        }];
    }
}

- (void)addTapped {
    ScannerViewController *scanner = [[ScannerViewController alloc] init];
    scanner.delegate = self;
    [self.navigationController pushViewController:scanner animated:YES];
}

- (void)editTapped {
    [self.tableView setEditing:!self.tableView.editing animated:YES];
    self.navigationItem.leftBarButtonItem.title = self.tableView.editing ? @"Done" : @"Edit";
}

- (void)filterChanged:(UISegmentedControl *)sender {
    [self reloadBooks];
}

- (void)pricingTapped {
    BOOL enabled = ![BKResalePriceClient isPricingModeEnabled];
    [BKResalePriceClient setPricingModeEnabled:enabled];
    [self updatePricingButton];
    [self reloadBooks];
    if (enabled) {
        [self refreshResalePricesIfNeeded:[[BKLibraryStore sharedStore] books] force:YES];
    }
}

- (void)updatePricingButton {
    BOOL enabled = [BKResalePriceClient isPricingModeEnabled];
    [self.pricingButton setTitle:enabled ? @"VALUE ON" : @"VALUE" forState:UIControlStateNormal];
    [self.pricingButton setTitleColor:enabled ? [UIColor colorWithRed:0.14 green:0.10 blue:0.07 alpha:1.0] : [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0] forState:UIControlStateNormal];
    self.pricingButton.backgroundColor = enabled ? [UIColor colorWithRed:0.68 green:0.82 blue:0.60 alpha:1.0] : [UIColor clearColor];
    self.pricingButton.layer.borderColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0].CGColor;
    self.pricingButton.layer.borderWidth = enabled ? 0.0 : 1.0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleBooks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BKBookCell *cell = [tableView dequeueReusableCellWithIdentifier:BKBookCellIdentifier forIndexPath:indexPath];
    [cell configureWithBook:self.visibleBooks[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    BKBook *book = self.visibleBooks[indexPath.row];
    BookDetailsViewController *details = [[BookDetailsViewController alloc] initWithBookIdentifier:book.identifier];
    [self.navigationController pushViewController:details animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        BKBook *book = self.visibleBooks[indexPath.row];
        [[BKLibraryStore sharedStore] deleteBook:book];
        [self reloadBooks];
    }
}

- (NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    BKBook *book = self.visibleBooks[indexPath.row];
    UITableViewRowAction *deleteAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive title:@"Delete" handler:^(UITableViewRowAction *action, NSIndexPath *path) {
        [[BKLibraryStore sharedStore] deleteBook:book];
        [self reloadBooks];
    }];
    UITableViewRowAction *editAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal title:@"Edit" handler:^(UITableViewRowAction *action, NSIndexPath *path) {
        [self presentEditorForBook:book];
    }];
    editAction.backgroundColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
    NSString *loanTitle = [[book.status lowercaseString] isEqualToString:@"loaned"] ? @"Return" : @"Loan";
    UITableViewRowAction *loanAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal title:loanTitle handler:^(UITableViewRowAction *action, NSIndexPath *path) {
        [self presentLoanFlowForBook:book];
    }];
    loanAction.backgroundColor = [UIColor colorWithRed:0.28 green:0.36 blue:0.27 alpha:1.0];
    return @[deleteAction, editAction, loanAction];
}

- (void)presentEditorForBook:(BKBook *)book {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Edit Book" message:@"Keep it concise for guests browsing the shelf." preferredStyle:UIAlertControllerStyleAlert];
    NSArray *values = @[book.title ?: @"", book.author ?: @"", book.status ?: @"Owned", book.shelf ?: @"", book.conditionText ?: @"", book.note ?: @""];
    NSArray *placeholders = @[@"Title", @"Author", @"Status: Owned, Read, Loaned", @"Shelf / location", @"Condition", @"Personal note"];
    for (NSUInteger index = 0; index < placeholders.count; index++) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = placeholders[index];
            textField.text = values[index];
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        book.title = alert.textFields[0].text.length ? alert.textFields[0].text : book.title;
        book.author = alert.textFields[1].text.length ? alert.textFields[1].text : book.author;
        book.status = alert.textFields[2].text.length ? alert.textFields[2].text : @"Owned";
        book.shelf = alert.textFields[3].text.length ? alert.textFields[3].text : @"Main shelf";
        book.conditionText = alert.textFields[4].text.length ? alert.textFields[4].text : @"Good";
        book.note = alert.textFields[5].text ?: @"";
        if (![[book.status lowercaseString] isEqualToString:@"loaned"]) {
            book.borrowerName = @"";
        }
        [[BKLibraryStore sharedStore] updateBook:book];
        [self reloadBooks];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentLoanFlowForBook:(BKBook *)book {
    if ([[book.status lowercaseString] isEqualToString:@"loaned"]) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Loaned Book" message:book.borrowerName.length ? [NSString stringWithFormat:@"Currently with %@", book.borrowerName] : nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Change Friend" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self presentBorrowerPromptForBook:book];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Mark Returned" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            book.status = @"Owned";
            book.borrowerName = @"";
            [[BKLibraryStore sharedStore] updateBook:book];
            [self reloadBooks];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    [self presentBorrowerPromptForBook:book];
}

- (void)presentBorrowerPromptForBook:(BKBook *)book {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Loan to Friend" message:@"Add the friend's name so guests know where the book is." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Friend's name";
        textField.text = book.borrowerName ?: @"";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save Loan" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length == 0) {
            return;
        }
        book.status = @"Loaned";
        book.borrowerName = name;
        [[BKLibraryStore sharedStore] updateBook:book];
        [self reloadBooks];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self reloadBooks];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)scannerDidAddBook {
    [self reloadBooks];
}

@end
