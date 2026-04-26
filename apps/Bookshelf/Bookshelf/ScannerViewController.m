#import "ScannerViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "BKCoverView.h"
#import "BKGoodreadsClient.h"
#import "BKLibraryStore.h"

@interface ScannerViewController () <AVCaptureMetadataOutputObjectsDelegate, UITextFieldDelegate>

@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) UIView *cameraView;
@property (nonatomic, strong) UIView *scanFrame;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *isbnField;
@property (nonatomic, strong) UIView *previewCard;
@property (nonatomic, strong) BKCoverView *coverView;
@property (nonatomic, strong) UILabel *previewTitleLabel;
@property (nonatomic, strong) UILabel *previewAuthorLabel;
@property (nonatomic, strong) UIButton *addButton;
@property (nonatomic, strong) BKBook *candidateBook;
@property (nonatomic) BOOL handledCode;

@end

@implementation ScannerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Scanner";
    self.view.backgroundColor = [UIColor colorWithRed:0.12 green:0.08 blue:0.055 alpha:1.0];
    [self buildInterface];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.handledCode = NO;
    [self configureCameraIfPossible];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.session stopRunning];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewLayer.frame = self.cameraView.bounds;
}

- (void)buildInterface {
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;

    self.cameraView = [[UIView alloc] initWithFrame:CGRectZero];
    self.cameraView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cameraView.backgroundColor = [UIColor colorWithRed:0.07 green:0.05 blue:0.04 alpha:1.0];
    self.cameraView.layer.cornerRadius = 8.0;
    self.cameraView.layer.masksToBounds = YES;
    [self.view addSubview:self.cameraView];

    self.scanFrame = [[UIView alloc] initWithFrame:CGRectZero];
    self.scanFrame.translatesAutoresizingMaskIntoConstraints = NO;
    self.scanFrame.layer.borderColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0].CGColor;
    self.scanFrame.layer.borderWidth = 2.0;
    self.scanFrame.layer.cornerRadius = 6.0;
    [self.cameraView addSubview:self.scanFrame];

    self.statusLabel = [self labelWithText:@"Point camera at an ISBN barcode" size:13.0 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.96 green:0.91 blue:0.82 alpha:1.0]];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [self.cameraView addSubview:self.statusLabel];

    self.isbnField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.isbnField.translatesAutoresizingMaskIntoConstraints = NO;
    self.isbnField.placeholder = @"Manual ISBN";
    self.isbnField.keyboardType = UIKeyboardTypeNumberPad;
    self.isbnField.delegate = self;
    self.isbnField.backgroundColor = [UIColor colorWithRed:0.96 green:0.91 blue:0.82 alpha:1.0];
    self.isbnField.textColor = [UIColor colorWithRed:0.16 green:0.11 blue:0.08 alpha:1.0];
    self.isbnField.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.isbnField.layer.cornerRadius = 7.0;
    self.isbnField.layer.masksToBounds = YES;
    self.isbnField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10.0, 1.0)];
    self.isbnField.leftViewMode = UITextFieldViewModeAlways;
    [self.isbnField addTarget:self action:@selector(isbnChanged:) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:self.isbnField];

    UIButton *lookupButton = [UIButton buttonWithType:UIButtonTypeCustom];
    lookupButton.translatesAutoresizingMaskIntoConstraints = NO;
    [lookupButton setTitle:@"Lookup" forState:UIControlStateNormal];
    [lookupButton setTitleColor:[UIColor colorWithRed:0.16 green:0.10 blue:0.07 alpha:1.0] forState:UIControlStateNormal];
    lookupButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBlack];
    lookupButton.backgroundColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
    lookupButton.layer.cornerRadius = 7.0;
    lookupButton.layer.masksToBounds = YES;
    [lookupButton addTarget:self action:@selector(lookupTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:lookupButton];

    self.previewCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.previewCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewCard.backgroundColor = [UIColor colorWithRed:0.19 green:0.13 blue:0.09 alpha:1.0];
    self.previewCard.layer.cornerRadius = 8.0;
    self.previewCard.layer.masksToBounds = YES;
    [self.view addSubview:self.previewCard];

    self.coverView = [[BKCoverView alloc] initWithFrame:CGRectZero];
    self.coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewCard addSubview:self.coverView];

    self.previewTitleLabel = [self labelWithText:@"Scan or type an ISBN" size:16.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.97 green:0.91 blue:0.82 alpha:1.0]];
    self.previewTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewTitleLabel.numberOfLines = 2;
    [self.previewCard addSubview:self.previewTitleLabel];

    self.previewAuthorLabel = [self labelWithText:@"Harry Potter ISBNs are recognized locally." size:12.0 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.79 green:0.70 blue:0.58 alpha:1.0]];
    self.previewAuthorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewAuthorLabel.numberOfLines = 2;
    [self.previewCard addSubview:self.previewAuthorLabel];

    self.addButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.addButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.addButton setTitle:@"Add Book" forState:UIControlStateNormal];
    [self.addButton setTitleColor:[UIColor colorWithRed:0.16 green:0.10 blue:0.07 alpha:1.0] forState:UIControlStateNormal];
    self.addButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBlack];
    self.addButton.backgroundColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
    self.addButton.layer.cornerRadius = 7.0;
    self.addButton.layer.masksToBounds = YES;
    self.addButton.enabled = NO;
    self.addButton.alpha = 0.45;
    [self.addButton addTarget:self action:@selector(addBookTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.previewCard addSubview:self.addButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.cameraView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [self.cameraView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [self.cameraView.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16.0],
        [self.cameraView.heightAnchor constraintEqualToConstant:258.0],

        [self.scanFrame.leadingAnchor constraintEqualToAnchor:self.cameraView.leadingAnchor constant:34.0],
        [self.scanFrame.trailingAnchor constraintEqualToAnchor:self.cameraView.trailingAnchor constant:-34.0],
        [self.scanFrame.centerYAnchor constraintEqualToAnchor:self.cameraView.centerYAnchor constant:-10.0],
        [self.scanFrame.heightAnchor constraintEqualToConstant:86.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.cameraView.leadingAnchor constant:14.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.cameraView.trailingAnchor constant:-14.0],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.cameraView.bottomAnchor constant:-16.0],

        [self.isbnField.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [self.isbnField.topAnchor constraintEqualToAnchor:self.cameraView.bottomAnchor constant:14.0],
        [self.isbnField.heightAnchor constraintEqualToConstant:44.0],

        [lookupButton.leadingAnchor constraintEqualToAnchor:self.isbnField.trailingAnchor constant:10.0],
        [lookupButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [lookupButton.centerYAnchor constraintEqualToAnchor:self.isbnField.centerYAnchor],
        [lookupButton.widthAnchor constraintEqualToConstant:82.0],
        [lookupButton.heightAnchor constraintEqualToConstant:44.0],

        [self.previewCard.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [self.previewCard.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [self.previewCard.topAnchor constraintEqualToAnchor:self.isbnField.bottomAnchor constant:14.0],
        [self.previewCard.heightAnchor constraintEqualToConstant:142.0],

        [self.coverView.leadingAnchor constraintEqualToAnchor:self.previewCard.leadingAnchor constant:12.0],
        [self.coverView.centerYAnchor constraintEqualToAnchor:self.previewCard.centerYAnchor],
        [self.coverView.widthAnchor constraintEqualToConstant:54.0],
        [self.coverView.heightAnchor constraintEqualToConstant:80.0],

        [self.previewTitleLabel.leadingAnchor constraintEqualToAnchor:self.coverView.trailingAnchor constant:12.0],
        [self.previewTitleLabel.trailingAnchor constraintEqualToAnchor:self.previewCard.trailingAnchor constant:-12.0],
        [self.previewTitleLabel.topAnchor constraintEqualToAnchor:self.previewCard.topAnchor constant:16.0],

        [self.previewAuthorLabel.leadingAnchor constraintEqualToAnchor:self.previewTitleLabel.leadingAnchor],
        [self.previewAuthorLabel.trailingAnchor constraintEqualToAnchor:self.previewTitleLabel.trailingAnchor],
        [self.previewAuthorLabel.topAnchor constraintEqualToAnchor:self.previewTitleLabel.bottomAnchor constant:6.0],

        [self.addButton.leadingAnchor constraintEqualToAnchor:self.previewTitleLabel.leadingAnchor],
        [self.addButton.trailingAnchor constraintEqualToAnchor:self.previewTitleLabel.trailingAnchor],
        [self.addButton.bottomAnchor constraintEqualToAnchor:self.previewCard.bottomAnchor constant:-12.0],
        [self.addButton.heightAnchor constraintEqualToConstant:36.0]
    ]];

    BKBook *placeholder = [BKBook catalogBookForISBN:@"9780590353427"];
    [self.coverView configureWithBook:placeholder compact:YES];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)configureCameraIfPossible {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    [self startCameraSession];
                } else {
                    self.statusLabel.text = @"Camera access denied. Type ISBN manually.";
                }
            });
        }];
    } else if (status == AVAuthorizationStatusAuthorized) {
        [self startCameraSession];
    } else {
        self.statusLabel.text = @"Camera unavailable. Type ISBN manually.";
    }
}

- (void)startCameraSession {
    if (self.session) {
        if (!self.session.running) {
            [self.session startRunning];
        }
        return;
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        self.statusLabel.text = @"No camera found. Type ISBN manually.";
        return;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || error) {
        self.statusLabel.text = @"Camera could not start. Type ISBN manually.";
        return;
    }

    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPresetMedium;
    if ([self.session canAddInput:input]) {
        [self.session addInput:input];
    }

    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    if ([self.session canAddOutput:output]) {
        [self.session addOutput:output];
        [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        NSArray *types = @[AVMetadataObjectTypeEAN13Code, AVMetadataObjectTypeEAN8Code, AVMetadataObjectTypeUPCECode, AVMetadataObjectTypeCode128Code];
        NSMutableArray *available = [NSMutableArray array];
        for (AVMetadataObjectType type in types) {
            if ([output.availableMetadataObjectTypes containsObject:type]) {
                [available addObject:type];
            }
        }
        output.metadataObjectTypes = available;
    }

    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.frame = self.cameraView.bounds;
    [self.cameraView.layer insertSublayer:self.previewLayer atIndex:0];
    [self.session startRunning];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    if (self.handledCode) {
        return;
    }
    for (AVMetadataObject *object in metadataObjects) {
        if ([object isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            NSString *value = [(AVMetadataMachineReadableCodeObject *)object stringValue];
            if (value.length > 0) {
                self.handledCode = YES;
                self.isbnField.text = value;
                [self useISBN:value];
                AudioServicesPlaySystemSound(1108);
                return;
            }
        }
    }
}

- (void)isbnChanged:(UITextField *)textField {
    self.handledCode = NO;
    if (textField.text.length >= 10) {
        [self useISBN:textField.text];
    }
}

- (void)lookupTapped {
    [self.isbnField resignFirstResponder];
    [self useISBN:self.isbnField.text];
}

- (void)useISBN:(NSString *)isbn {
    NSString *normalized = [[isbn componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (normalized.length < 10) {
        self.statusLabel.text = @"Enter a 10 or 13 digit ISBN.";
        return;
    }
    BKBook *candidate = [BKBook catalogBookForISBN:normalized];
    self.candidateBook = candidate;
    [self.coverView configureWithBook:candidate compact:YES];
    self.previewTitleLabel.text = candidate.title;
    self.previewAuthorLabel.text = candidate.author;
    self.statusLabel.text = [NSString stringWithFormat:@"Ready: %@", normalized];
    self.addButton.enabled = YES;
    self.addButton.alpha = 1.0;
    [[BKGoodreadsClient sharedClient] enrichBook:candidate completion:^(BOOL changed) {
        if (changed && self.candidateBook == candidate) {
            [self.coverView configureWithBook:candidate compact:YES];
            self.previewTitleLabel.text = candidate.title;
            NSString *rating = candidate.goodreadsAverageRating.length ? [NSString stringWithFormat:@" • GR %@", candidate.goodreadsAverageRating] : @"";
            self.previewAuthorLabel.text = [NSString stringWithFormat:@"%@%@", candidate.author, rating];
        }
    }];
}

- (void)addBookTapped {
    if (!self.candidateBook) {
        return;
    }
    if ([[BKLibraryStore sharedStore] containsISBN:self.candidateBook.isbn]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Already on Shelf" message:@"This ISBN is already in your collection." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [[BKLibraryStore sharedStore] addBook:self.candidateBook];
    [self.delegate scannerDidAddBook];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Added" message:self.candidateBook.title preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self lookupTapped];
    return YES;
}

@end
