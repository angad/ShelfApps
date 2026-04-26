#import "BKGoodreadsClient.h"

@interface BKGoodreadsClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlightISBNs;

@end

@implementation BKGoodreadsClient

+ (instancetype)sharedClient {
    static BKGoodreadsClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[BKGoodreadsClient alloc] initPrivate];
    });
    return client;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 16.0;
        self.session = [NSURLSession sessionWithConfiguration:configuration];
        self.inFlightISBNs = [NSMutableSet set];
    }
    return self;
}

- (void)enrichBook:(BKBook *)book completion:(void (^)(BOOL changed))completion {
    NSString *isbn = [[book.isbn componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (isbn.length == 0) {
        if (completion) {
            completion(NO);
        }
        return;
    }
    @synchronized (self.inFlightISBNs) {
        if ([self.inFlightISBNs containsObject:isbn]) {
            if (completion) {
                completion(NO);
            }
            return;
        }
        [self.inFlightISBNs addObject:isbn];
    }

    NSString *escaped = [isbn stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://www.goodreads.com/book/auto_complete?format=json&q=%@", escaped ?: isbn];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 12_5 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL changed = NO;
        if (data.length > 0 && !error) {
            id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *item = ([payload isKindOfClass:[NSArray class]] && [payload count] > 0) ? [payload firstObject] : nil;
            if ([item isKindOfClass:[NSDictionary class]]) {
                changed = [self applyItem:item toBook:book];
            }
        }
        @synchronized (self.inFlightISBNs) {
            [self.inFlightISBNs removeObject:isbn];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(changed);
            }
        });
    }];
    [task resume];
}

- (BOOL)applyItem:(NSDictionary *)item toBook:(BKBook *)book {
    BOOL changed = NO;
    NSString *bareTitle = [self stringValue:item[@"bookTitleBare"]];
    if (bareTitle.length > 0 && ([book.title hasPrefix:@"Scanned Book"] || [book.title isEqualToString:@"Untitled Book"])) {
        book.title = bareTitle;
        changed = YES;
    }

    NSDictionary *author = [item[@"author"] isKindOfClass:[NSDictionary class]] ? item[@"author"] : nil;
    NSString *authorName = [self stringValue:author[@"name"]];
    if (authorName.length > 0 && ([book.author isEqualToString:@"Unknown Author"] || book.author.length == 0)) {
        book.author = authorName;
        changed = YES;
    }

    NSString *imageURL = [self largerCoverURL:[self stringValue:item[@"imageUrl"]]];
    if (imageURL.length > 0 && ![book.coverImageURL isEqualToString:imageURL]) {
        book.coverImageURL = imageURL;
        changed = YES;
    }

    NSString *bookURL = [self stringValue:item[@"bookUrl"]];
    if ([bookURL hasPrefix:@"/"]) {
        bookURL = [@"https://www.goodreads.com" stringByAppendingString:bookURL];
    }
    if (bookURL.length > 0 && ![book.goodreadsBookURL isEqualToString:bookURL]) {
        book.goodreadsBookURL = bookURL;
        changed = YES;
    }

    NSString *rating = [self stringValue:item[@"avgRating"]];
    if (rating.length > 0 && ![book.goodreadsAverageRating isEqualToString:rating]) {
        book.goodreadsAverageRating = rating;
        changed = YES;
    }

    NSString *ratingsCount = [self stringValue:item[@"ratingsCount"]];
    if (ratingsCount.length > 0 && ![book.goodreadsRatingsCount isEqualToString:ratingsCount]) {
        book.goodreadsRatingsCount = ratingsCount;
        changed = YES;
    }
    return changed;
}

- (NSString *)stringValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    }
    return @"";
}

- (NSString *)largerCoverURL:(NSString *)urlString {
    if (urlString.length == 0) {
        return @"";
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\._S[XY][0-9]+_\\.jpg" options:0 error:nil];
    NSRange range = NSMakeRange(0, urlString.length);
    NSString *updated = [regex stringByReplacingMatchesInString:urlString options:0 range:range withTemplate:@"._SX160_.jpg"];
    return updated.length > 0 ? updated : urlString;
}

@end
