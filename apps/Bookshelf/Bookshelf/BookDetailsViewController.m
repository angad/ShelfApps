#import "BookDetailsViewController.h"
#import "BKCoverView.h"
#import "BKGoodreadsClient.h"
#import "BKLibraryStore.h"
#import "BKResalePriceClient.h"

@interface BookDetailsViewController ()

@property (nonatomic, copy) NSString *bookIdentifier;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;

@end

@implementation BookDetailsViewController

- (instancetype)initWithBookIdentifier:(NSString *)bookIdentifier {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _bookIdentifier = [bookIdentifier copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Book";
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.91 blue:0.82 alpha:1.0];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit target:self action:@selector(editTapped)];
    [self buildInterface];
    [self enrichBookIfNeeded];
    [self render];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self render];
}

- (BKBook *)book {
    return [[BKLibraryStore sharedStore] bookWithIdentifier:self.bookIdentifier];
}

- (void)buildInterface {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 12.0;
    self.stackView.layoutMargins = UIEdgeInsetsMake(16.0, 16.0, 24.0, 16.0);
    self.stackView.layoutMarginsRelativeArrangement = YES;
    [self.scrollView addSubview:self.stackView];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [self.stackView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor]
    ]];
}

- (void)render {
    for (UIView *view in self.stackView.arrangedSubviews) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    BKBook *book = [self book];
    if (!book) {
        UILabel *missing = [self labelWithText:@"This book is no longer on the shelf." size:16.0 weight:UIFontWeightSemibold color:[self inkColor]];
        missing.numberOfLines = 0;
        [self.stackView addArrangedSubview:missing];
        return;
    }

    UIStackView *hero = [[UIStackView alloc] initWithFrame:CGRectZero];
    hero.axis = UILayoutConstraintAxisHorizontal;
    hero.alignment = UIStackViewAlignmentCenter;
    hero.spacing = 16.0;

    BKCoverView *cover = [[BKCoverView alloc] initWithFrame:CGRectZero];
    [cover configureWithBook:book compact:NO];
    [hero addArrangedSubview:cover];
    [cover.widthAnchor constraintEqualToConstant:102.0].active = YES;
    [cover.heightAnchor constraintEqualToConstant:150.0].active = YES;

    UILabel *title = [self labelWithText:book.title size:22.0 weight:UIFontWeightBlack color:[self inkColor]];
    title.numberOfLines = 4;
    UILabel *author = [self labelWithText:book.author size:14.0 weight:UIFontWeightSemibold color:[self mutedColor]];
    UILabel *status = [self pillLabelWithText:[book.status uppercaseString]];
    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[title, author, status]];
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.spacing = 8.0;
    titleStack.alignment = UIStackViewAlignmentLeading;
    [hero addArrangedSubview:titleStack];
    [self.stackView addArrangedSubview:hero];

    [self.stackView addArrangedSubview:[self divider]];
    [self.stackView addArrangedSubview:[self infoRowTitle:@"ISBN" value:book.isbn.length ? book.isbn : @"Not set"]];
    [self.stackView addArrangedSubview:[self infoRowTitle:@"Published" value:book.year.length ? book.year : @"Not set"]];
    if (book.goodreadsAverageRating.length > 0) {
        [self.stackView addArrangedSubview:[self infoRowTitle:@"Goodreads" value:[self goodreadsRatingTextForBook:book]]];
    }
    if ([BKResalePriceClient isPricingModeEnabled]) {
        [self.stackView addArrangedSubview:[self infoRowTitle:@"Resale" value:[self resalePriceTextForBook:book]]];
    }
    [self.stackView addArrangedSubview:[self infoRowTitle:@"Shelf" value:book.shelf.length ? book.shelf : @"Main shelf"]];
    [self.stackView addArrangedSubview:[self infoRowTitle:@"Condition" value:book.conditionText.length ? book.conditionText : @"Good"]];
    if ([[book.status lowercaseString] isEqualToString:@"loaned"]) {
        [self.stackView addArrangedSubview:[self infoRowTitle:@"Loaned To" value:book.borrowerName.length ? book.borrowerName : @"Friend"]];
    }
    [self.stackView addArrangedSubview:[self noteBlock:book.note.length ? book.note : @"No personal note yet."]];

    UIButton *loanButton = [self actionButtonWithTitle:[[book.status lowercaseString] isEqualToString:@"loaned"] ? @"Return / Edit Loan" : @"Loan to Friend" selector:@selector(loanTapped)];
    loanButton.backgroundColor = [UIColor colorWithRed:0.28 green:0.36 blue:0.27 alpha:1.0];
    [self.stackView addArrangedSubview:loanButton];

    if ([BKResalePriceClient isPricingModeEnabled]) {
        UIButton *priceButton = [self actionButtonWithTitle:book.resaleURL.length ? @"Open Price Quote" : @"Refresh Resale Price" selector:@selector(resaleTapped)];
        priceButton.backgroundColor = [UIColor colorWithRed:0.24 green:0.34 blue:0.22 alpha:1.0];
        [self.stackView addArrangedSubview:priceButton];
    }

    UIStackView *linkRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    linkRow.axis = UILayoutConstraintAxisHorizontal;
    linkRow.spacing = 10.0;
    linkRow.distribution = UIStackViewDistributionFillEqually;
    [linkRow addArrangedSubview:[self actionButtonWithTitle:@"Goodreads" selector:@selector(openGoodreads)]];
    [linkRow addArrangedSubview:[self actionButtonWithTitle:@"Reviews" selector:@selector(openReviews)]];
    [self.stackView addArrangedSubview:linkRow];

    UIButton *deleteButton = [self actionButtonWithTitle:@"Delete from shelf" selector:@selector(deleteTapped)];
    deleteButton.backgroundColor = [UIColor colorWithRed:0.55 green:0.16 blue:0.13 alpha:1.0];
    [self.stackView addArrangedSubview:deleteButton];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (UILabel *)pillLabelWithText:(NSString *)text {
    UILabel *label = [self labelWithText:text size:10.0 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    label.backgroundColor = [UIColor colorWithRed:0.47 green:0.14 blue:0.10 alpha:1.0];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 4.0;
    label.layer.masksToBounds = YES;
    [label.widthAnchor constraintGreaterThanOrEqualToConstant:58.0].active = YES;
    [label.heightAnchor constraintEqualToConstant:24.0].active = YES;
    return label;
}

- (UIView *)divider {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [UIColor colorWithRed:0.73 green:0.65 blue:0.53 alpha:0.65];
    [view.heightAnchor constraintEqualToConstant:1.0].active = YES;
    return view;
}

- (UIView *)infoRowTitle:(NSString *)title value:(NSString *)value {
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentFirstBaseline;
    row.spacing = 12.0;

    UILabel *left = [self labelWithText:title size:11.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.47 green:0.14 blue:0.10 alpha:1.0]];
    UILabel *right = [self labelWithText:value size:14.0 weight:UIFontWeightSemibold color:[self inkColor]];
    right.numberOfLines = 2;
    right.textAlignment = NSTextAlignmentRight;
    [left.widthAnchor constraintEqualToConstant:82.0].active = YES;
    [row addArrangedSubview:left];
    [row addArrangedSubview:right];
    return row;
}

- (UIView *)noteBlock:(NSString *)note {
    UIView *block = [[UIView alloc] initWithFrame:CGRectZero];
    block.backgroundColor = [UIColor colorWithRed:0.90 green:0.83 blue:0.70 alpha:1.0];
    block.layer.cornerRadius = 7.0;
    block.layer.masksToBounds = YES;

    UILabel *caption = [self labelWithText:@"PERSONAL NOTE" size:10.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.47 green:0.14 blue:0.10 alpha:1.0]];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    [block addSubview:caption];

    UILabel *body = [self labelWithText:note size:14.0 weight:UIFontWeightRegular color:[self inkColor]];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.numberOfLines = 0;
    [block addSubview:body];

    [NSLayoutConstraint activateConstraints:@[
        [caption.leadingAnchor constraintEqualToAnchor:block.leadingAnchor constant:12.0],
        [caption.trailingAnchor constraintEqualToAnchor:block.trailingAnchor constant:-12.0],
        [caption.topAnchor constraintEqualToAnchor:block.topAnchor constant:10.0],

        [body.leadingAnchor constraintEqualToAnchor:block.leadingAnchor constant:12.0],
        [body.trailingAnchor constraintEqualToAnchor:block.trailingAnchor constant:-12.0],
        [body.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:7.0],
        [body.bottomAnchor constraintEqualToAnchor:block.bottomAnchor constant:-12.0]
    ]];
    return block;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithRed:0.98 green:0.92 blue:0.78 alpha:1.0] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
    button.backgroundColor = [UIColor colorWithRed:0.16 green:0.10 blue:0.07 alpha:1.0];
    button.layer.cornerRadius = 7.0;
    button.layer.masksToBounds = YES;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:44.0].active = YES;
    return button;
}

- (UIColor *)inkColor {
    return [UIColor colorWithRed:0.16 green:0.11 blue:0.08 alpha:1.0];
}

- (UIColor *)mutedColor {
    return [UIColor colorWithRed:0.42 green:0.34 blue:0.25 alpha:1.0];
}

- (void)editTapped {
    BKBook *book = [self book];
    if (!book) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Edit Book" message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSArray *values = @[book.title ?: @"", book.author ?: @"", book.status ?: @"Owned", book.shelf ?: @"", book.conditionText ?: @"", book.note ?: @""];
    NSArray *placeholders = @[@"Title", @"Author", @"Status", @"Shelf / location", @"Condition", @"Personal note"];
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
        [self render];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loanTapped {
    BKBook *book = [self book];
    if (!book) {
        return;
    }
    if ([[book.status lowercaseString] isEqualToString:@"loaned"]) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Loaned Book" message:book.borrowerName.length ? [NSString stringWithFormat:@"Currently with %@", book.borrowerName] : nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Change Friend" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self presentBorrowerPromptForBook:book];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Mark Returned" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            book.status = @"Owned";
            book.borrowerName = @"";
            [[BKLibraryStore sharedStore] updateBook:book];
            [self render];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    [self presentBorrowerPromptForBook:book];
}

- (void)presentBorrowerPromptForBook:(BKBook *)book {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Loan to Friend" message:@"Add the friend's name for this loan." preferredStyle:UIAlertControllerStyleAlert];
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
        [self render];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteTapped {
    BKBook *book = [self book];
    if (!book) {
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Book" message:@"Remove this book from your shelf?" preferredStyle:UIAlertControllerStyleActionSheet];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[BKLibraryStore sharedStore] deleteBook:book];
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)openGoodreads {
    BKBook *book = [self book];
    if (book.goodreadsBookURL.length > 0) {
        NSURL *url = [NSURL URLWithString:book.goodreadsBookURL];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return;
        }
    }
    [self openSearchURLWithBase:@"https://www.goodreads.com/search?q=" book:book];
}

- (void)openReviews {
    BKBook *book = [self book];
    [self openSearchURLWithBase:@"https://www.google.com/search?q=" book:book suffix:@" reviews"];
}

- (void)resaleTapped {
    BKBook *book = [self book];
    if (book.resaleURL.length > 0) {
        NSURL *url = [NSURL URLWithString:book.resaleURL];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return;
        }
    }
    [[BKResalePriceClient sharedClient] refreshBookIfNeeded:book force:YES completion:^(BOOL changed) {
        if (changed) {
            [[BKLibraryStore sharedStore] updateBook:book];
        }
        [self render];
    }];
}

- (void)openSearchURLWithBase:(NSString *)base book:(BKBook *)book {
    [self openSearchURLWithBase:base book:book suffix:@""];
}

- (void)openSearchURLWithBase:(NSString *)base book:(BKBook *)book suffix:(NSString *)suffix {
    NSString *query = [NSString stringWithFormat:@"%@ %@%@", book.title ?: @"", book.author ?: @"", suffix ?: @""];
    NSString *escaped = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:escaped ?: @""]];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (NSString *)goodreadsRatingTextForBook:(BKBook *)book {
    if (book.goodreadsRatingsCount.length == 0) {
        return [NSString stringWithFormat:@"%@ average", book.goodreadsAverageRating];
    }
    NSNumberFormatter *reader = [[NSNumberFormatter alloc] init];
    NSNumber *count = [reader numberFromString:book.goodreadsRatingsCount];
    NSNumberFormatter *writer = [[NSNumberFormatter alloc] init];
    writer.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *formatted = count ? [writer stringFromNumber:count] : book.goodreadsRatingsCount;
    return [NSString stringWithFormat:@"%@ average from %@ ratings", book.goodreadsAverageRating, formatted];
}

- (NSString *)resalePriceTextForBook:(BKBook *)book {
    if (book.resalePrice.length == 0) {
        return book.resalePriceError.length ? book.resalePriceError : @"Checking daily";
    }
    NSString *vendor = book.resaleVendor.length ? book.resaleVendor : @"second-hand market";
    NSString *dateText = [self resaleDateTextForBook:book];
    if (dateText.length > 0) {
        return [NSString stringWithFormat:@"%@ from %@, %@", book.resalePrice, vendor, dateText];
    }
    return [NSString stringWithFormat:@"%@ from %@", book.resalePrice, vendor];
}

- (NSString *)resaleDateTextForBook:(BKBook *)book {
    NSTimeInterval timestamp = [book.resalePriceUpdatedAt doubleValue];
    if (timestamp <= 0) {
        return @"";
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterNoStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

- (void)enrichBookIfNeeded {
    BKBook *book = [self book];
    if (!book || book.isbn.length == 0 || (book.goodreadsAverageRating.length > 0 && book.coverImageURL.length > 0)) {
        return;
    }
    [[BKGoodreadsClient sharedClient] enrichBook:book completion:^(BOOL changed) {
        if (changed) {
            [[BKLibraryStore sharedStore] updateBook:book];
            [self render];
        }
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    BKBook *book = [self book];
    if (![BKResalePriceClient isPricingModeEnabled] || !book) {
        return;
    }
    [[BKResalePriceClient sharedClient] refreshBookIfNeeded:book force:NO completion:^(BOOL changed) {
        if (changed) {
            [[BKLibraryStore sharedStore] updateBook:book];
            [self render];
        }
    }];
}

@end
