#import "BKCoverView.h"
#import "BKImageLoader.h"

@interface BKCoverView ()

@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UIView *spineLine;
@property (nonatomic, copy) NSString *representedURL;

@end

@implementation BKCoverView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 5.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;

        self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds = YES;
        self.imageView.hidden = YES;
        [self addSubview:self.imageView];

        self.spineLine = [[UIView alloc] initWithFrame:CGRectZero];
        self.spineLine.translatesAutoresizingMaskIntoConstraints = NO;
        self.spineLine.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
        [self addSubview:self.spineLine];

        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.textColor = [UIColor colorWithRed:0.98 green:0.92 blue:0.78 alpha:1.0];
        self.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBlack];
        self.titleLabel.numberOfLines = 4;
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.72;
        [self addSubview:self.titleLabel];

        self.authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.authorLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
        self.authorLabel.font = [UIFont systemFontOfSize:7.0 weight:UIFontWeightSemibold];
        self.authorLabel.numberOfLines = 1;
        self.authorLabel.textAlignment = NSTextAlignmentCenter;
        self.authorLabel.adjustsFontSizeToFitWidth = YES;
        self.authorLabel.minimumScaleFactor = 0.6;
        [self addSubview:self.authorLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.imageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.imageView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.imageView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.imageView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [self.spineLine.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6.0],
            [self.spineLine.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.spineLine.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.spineLine.widthAnchor constraintEqualToConstant:2.0],

            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7.0],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-6.0],

            [self.authorLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:9.0],
            [self.authorLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6.0],
            [self.authorLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8.0]
        ]];
    }
    return self;
}

- (void)configureWithBook:(BKBook *)book compact:(BOOL)compact {
    self.backgroundColor = [book coverColor];
    self.titleLabel.text = [book.title uppercaseString];
    self.authorLabel.text = [book.author uppercaseString];
    self.titleLabel.font = [UIFont systemFontOfSize:compact ? 8.0 : 13.0 weight:UIFontWeightBlack];
    self.authorLabel.font = [UIFont systemFontOfSize:compact ? 6.0 : 9.0 weight:UIFontWeightSemibold];
    self.representedURL = book.coverImageURL ?: @"";
    self.imageView.hidden = YES;
    self.titleLabel.hidden = NO;
    self.authorLabel.hidden = NO;
    self.spineLine.hidden = NO;
    if (self.representedURL.length > 0) {
        NSString *expectedURL = [self.representedURL copy];
        [[BKImageLoader sharedLoader] loadImageWithURLString:expectedURL completion:^(UIImage *image) {
            if (![self.representedURL isEqualToString:expectedURL]) {
                return;
            }
            self.imageView.image = image;
            self.imageView.hidden = (image == nil);
            self.titleLabel.hidden = (image != nil);
            self.authorLabel.hidden = (image != nil);
            self.spineLine.hidden = (image != nil);
        }];
    } else {
        self.titleLabel.hidden = NO;
        self.authorLabel.hidden = NO;
        self.spineLine.hidden = NO;
    }
}

@end
