#import "BKResalePriceClient.h"

static NSString * const BKPricingModeDefaultsKey = @"Bookshelf.PricingModeEnabled.v1";
static NSTimeInterval const BKResaleRefreshInterval = 24.0 * 60.0 * 60.0;

@interface BKResaleOffer : NSObject

@property (nonatomic, strong) NSDecimalNumber *price;
@property (nonatomic, copy) NSString *currency;
@property (nonatomic, copy) NSString *vendor;
@property (nonatomic, copy) NSString *urlString;

@end

@implementation BKResaleOffer
@end

@interface BKResaleRefreshRequest : NSObject

@property (nonatomic, strong) BKBook *book;
@property (nonatomic, copy) NSString *isbn;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) void (^completion)(BOOL changed);

@end

@implementation BKResaleRefreshRequest
@end

@interface BKResalePriceClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlightISBNs;
@property (nonatomic, strong) NSMutableArray<BKResaleRefreshRequest *> *pendingRefreshes;
@property (nonatomic, assign) BOOL processingRefresh;

@end

@implementation BKResalePriceClient

+ (instancetype)sharedClient {
    static BKResalePriceClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[BKResalePriceClient alloc] initPrivate];
    });
    return client;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 12.0;
        self.session = [NSURLSession sessionWithConfiguration:configuration];
        self.inFlightISBNs = [NSMutableSet set];
        self.pendingRefreshes = [NSMutableArray array];
    }
    return self;
}

+ (BOOL)isPricingModeEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:BKPricingModeDefaultsKey];
}

+ (void)setPricingModeEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:BKPricingModeDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)refreshBookIfNeeded:(BKBook *)book force:(BOOL)force completion:(void (^)(BOOL changed))completion {
    if (!book || book.isbn.length == 0 || ![BKResalePriceClient isPricingModeEnabled]) {
        if (completion) {
            completion(NO);
        }
        return;
    }
    NSTimeInterval lastRefresh = [book.resalePriceUpdatedAt doubleValue];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && lastRefresh > 0 && now - lastRefresh < BKResaleRefreshInterval) {
        if (completion) {
            completion(NO);
        }
        return;
    }
    NSString *isbn = [self normalizedISBN:book.isbn];
    if (isbn.length == 0 || [self.inFlightISBNs containsObject:isbn]) {
        if (completion) {
            completion(NO);
        }
        return;
    }

    NSString *template = [self configurationStringForKey:@"BKPricingEndpointURLTemplate"];
    if (template.length == 0) {
        BOOL changed = [self applyError:@"Pricing API not configured" toBook:book];
        if (completion) {
            completion(changed);
        }
        return;
    }

    NSString *escapedISBN = [isbn stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [template stringByReplacingOccurrencesOfString:@"{isbn}" withString:escapedISBN ?: isbn];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        BOOL changed = [self applyError:@"Bad pricing URL" toBook:book];
        if (completion) {
            completion(changed);
        }
        return;
    }

    [self.inFlightISBNs addObject:isbn];
    BKResaleRefreshRequest *refresh = [[BKResaleRefreshRequest alloc] init];
    refresh.book = book;
    refresh.isbn = isbn;
    refresh.url = url;
    refresh.completion = completion;
    [self.pendingRefreshes addObject:refresh];
    [self processNextRefreshIfIdle];
}

- (void)processNextRefreshIfIdle {
    if (self.processingRefresh || self.pendingRefreshes.count == 0) {
        return;
    }
    self.processingRefresh = YES;
    BKResaleRefreshRequest *refresh = self.pendingRefreshes.firstObject;
    [self.pendingRefreshes removeObjectAtIndex:0];
    [self startRefresh:refresh];
}

- (void)startRefresh:(BKResaleRefreshRequest *)refresh {
    NSString *isbn = refresh.isbn;
    BKBook *book = refresh.book;
    void (^completion)(BOOL changed) = refresh.completion;
    NSURL *url = refresh.url;

    if ([url.host containsString:@"thriftbooks.com"]) {
        [self refreshThriftBooksQuoteForISBN:isbn book:book completion:completion];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSString *key = [self configurationStringForKey:@"BKPricingAPIKey"];
    if (key.length > 0) {
        NSString *header = [self configurationStringForKey:@"BKPricingAPIKeyHeader"];
        [request setValue:key forHTTPHeaderField:header.length ? header : @"Authorization"];
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Bookshelf/1.0 iOS12" forHTTPHeaderField:@"User-Agent"];

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL changed = NO;
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || http.statusCode >= 400 || data.length == 0) {
                changed = [self applyError:http.statusCode == 401 ? @"ThriftBooks login expired" : @"No price quote" toBook:book];
            } else {
                id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                BKResaleOffer *offer = [self bestOfferFromPayload:payload];
                if (offer) {
                    changed = [self applyOffer:offer toBook:book];
                } else {
                    changed = [self applyError:@"No buyback offer" toBook:book];
                }
            }
            [self finishRefreshForISBN:isbn changed:changed completion:completion];
        });
    }] resume];
}

- (void)refreshThriftBooksQuoteForISBN:(NSString *)isbn book:(BKBook *)book completion:(void (^)(BOOL changed))completion {
    [self installThriftBooksCookiesIfNeeded];
    NSURL *tokenURL = [NSURL URLWithString:@"https://www.thriftbooks.com/tb-api/csrf/GetToken"];
    NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
    [tokenRequest setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [tokenRequest setValue:@"https://www.thriftbooks.com/buyback/" forHTTPHeaderField:@"Referer"];
    [tokenRequest setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 12_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Bookshelf/1.0" forHTTPHeaderField:@"User-Agent"];

    [[self.session dataTaskWithRequest:tokenRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || http.statusCode >= 400 || data.length == 0) {
            [self finishThriftBooksQuoteForISBN:isbn book:book payload:nil errorText:http.statusCode == 401 ? @"ThriftBooks login expired" : @"No CSRF token" completion:completion];
            return;
        }
        id tokenPayload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *token = [tokenPayload isKindOfClass:[NSDictionary class]] ? [self stringFromObject:tokenPayload[@"token"]] : @"";
        if (token.length == 0) {
            [self finishThriftBooksQuoteForISBN:isbn book:book payload:nil errorText:@"No CSRF token" completion:completion];
            return;
        }

        NSURL *quoteURL = [NSURL URLWithString:@"https://www.thriftbooks.com/tb-api/buyback/get-quotes/"];
        NSMutableURLRequest *quoteRequest = [NSMutableURLRequest requestWithURL:quoteURL];
        quoteRequest.HTTPMethod = @"POST";
        quoteRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"identifiers": @[isbn], @"addedFrom": @3} options:0 error:nil];
        [quoteRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [quoteRequest setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
        [quoteRequest setValue:@"https://www.thriftbooks.com" forHTTPHeaderField:@"Origin"];
        [quoteRequest setValue:@"https://www.thriftbooks.com/buyback/" forHTTPHeaderField:@"Referer"];
        [quoteRequest setValue:@"same-origin" forHTTPHeaderField:@"Sec-Fetch-Site"];
        [quoteRequest setValue:@"cors" forHTTPHeaderField:@"Sec-Fetch-Mode"];
        [quoteRequest setValue:@"empty" forHTTPHeaderField:@"Sec-Fetch-Dest"];
        [quoteRequest setValue:token forHTTPHeaderField:@"X-XSRF-TOKEN"];
        [quoteRequest setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 12_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Bookshelf/1.0" forHTTPHeaderField:@"User-Agent"];

        [[self.session dataTaskWithRequest:quoteRequest completionHandler:^(NSData *quoteData, NSURLResponse *quoteResponse, NSError *quoteError) {
            NSHTTPURLResponse *quoteHTTP = [quoteResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)quoteResponse : nil;
            if (quoteError || quoteHTTP.statusCode >= 400 || quoteData.length == 0) {
                [self finishThriftBooksQuoteForISBN:isbn book:book payload:nil errorText:quoteHTTP.statusCode == 401 ? @"ThriftBooks login expired" : @"No price quote" completion:completion];
                return;
            }
            id payload = [NSJSONSerialization JSONObjectWithData:quoteData options:0 error:nil];
            [self finishThriftBooksQuoteForISBN:isbn book:book payload:payload errorText:nil completion:completion];
        }] resume];
    }] resume];
}

- (void)finishThriftBooksQuoteForISBN:(NSString *)isbn book:(BKBook *)book payload:(id)payload errorText:(NSString *)errorText completion:(void (^)(BOOL changed))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL changed = NO;
        if (errorText.length > 0) {
            changed = [self applyError:errorText toBook:book];
        } else {
            BKResaleOffer *offer = [self bestOfferFromPayload:payload];
            if (offer) {
                offer.vendor = offer.vendor.length ? offer.vendor : @"ThriftBooks";
                changed = [self applyOffer:offer toBook:book];
            } else {
                changed = [self applyError:@"No buyback offer" toBook:book];
            }
        }
        [self finishRefreshForISBN:isbn changed:changed completion:completion];
    });
}

- (void)finishRefreshForISBN:(NSString *)isbn changed:(BOOL)changed completion:(void (^)(BOOL changed))completion {
    [self.inFlightISBNs removeObject:isbn];
    self.processingRefresh = NO;
    if (completion) {
        completion(changed);
    }
    [self processNextRefreshIfIdle];
}

- (BOOL)applyOffer:(BKResaleOffer *)offer toBook:(BKBook *)book {
    NSString *price = [self formattedPrice:offer.price currency:offer.currency];
    NSString *vendor = offer.vendor.length ? offer.vendor : [self configurationStringForKey:@"BKPricingSourceName"];
    if (vendor.length == 0) {
        vendor = @"Resale market";
    }
    NSString *updated = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    BOOL changed = ![book.resalePrice isEqualToString:price] ||
        ![book.resaleVendor isEqualToString:vendor] ||
        ![book.resaleURL isEqualToString:(offer.urlString ?: @"")] ||
        book.resalePriceError.length > 0;
    book.resalePrice = price;
    book.resaleVendor = vendor;
    book.resaleURL = offer.urlString ?: @"";
    book.resalePriceUpdatedAt = updated;
    book.resalePriceError = @"";
    return changed;
}

- (BOOL)applyError:(NSString *)error toBook:(BKBook *)book {
    NSString *updated = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    BOOL changed = ![book.resalePriceError isEqualToString:error] || book.resalePriceUpdatedAt.length == 0;
    book.resalePriceError = error ?: @"Price unavailable";
    book.resalePriceUpdatedAt = updated;
    return changed;
}

- (BKResaleOffer *)bestOfferFromPayload:(id)payload {
    NSMutableArray<BKResaleOffer *> *offers = [NSMutableArray array];
    [self collectOffersFromObject:payload into:offers inheritedVendor:nil];
    BKResaleOffer *best = nil;
    for (BKResaleOffer *offer in offers) {
        if (!offer.price) {
            continue;
        }
        if (!best || [offer.price compare:best.price] == NSOrderedDescending) {
            best = offer;
        }
    }
    return best;
}

- (void)collectOffersFromObject:(id)object into:(NSMutableArray<BKResaleOffer *> *)offers inheritedVendor:(NSString *)vendor {
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            [self collectOffersFromObject:item into:offers inheritedVendor:vendor];
        }
        return;
    }
    if (![object isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    NSString *localVendor = [self vendorFromDictionary:dictionary] ?: vendor;
    NSDecimalNumber *price = [self priceFromDictionary:dictionary];
    if (price) {
        BKResaleOffer *offer = [[BKResaleOffer alloc] init];
        offer.price = price;
        offer.currency = [self stringFromObject:dictionary[@"currency"]] ?: @"USD";
        offer.vendor = localVendor ?: @"";
        offer.urlString = [self urlFromDictionary:dictionary] ?: @"";
        [offers addObject:offer];
    }

    for (id value in dictionary.allValues) {
        if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
            [self collectOffersFromObject:value into:offers inheritedVendor:localVendor];
        }
    }
}

- (NSDecimalNumber *)priceFromDictionary:(NSDictionary *)dictionary {
    NSArray *keys = @[@"quotePrice", @"buybackPrice", @"sellPrice", @"price", @"amount", @"maxPrice", @"total_price", @"totalPrice"];
    for (NSString *key in keys) {
        NSDecimalNumber *number = [self decimalFromObject:dictionary[key]];
        if (number && [number compare:[NSDecimalNumber zero]] != NSOrderedAscending) {
            return number;
        }
    }
    return nil;
}

- (NSString *)vendorFromDictionary:(NSDictionary *)dictionary {
    NSArray *keys = @[@"vendor", @"vendorName", @"merchant", @"merchantName", @"store", @"storeName", @"name", @"source"];
    for (NSString *key in keys) {
        NSString *value = [self stringFromObject:dictionary[key]];
        if (value.length > 0) {
            return value;
        }
    }
    id shop = dictionary[@"shop"];
    if ([shop isKindOfClass:[NSDictionary class]]) {
        return [self stringFromObject:shop[@"shop_name"]] ?: [self stringFromObject:shop[@"name"]];
    }
    return nil;
}

- (NSString *)urlFromDictionary:(NSDictionary *)dictionary {
    NSArray *keys = @[@"offerUrl", @"offer_url", @"url", @"link", @"checkoutUrl", @"vendorURL"];
    for (NSString *key in keys) {
        NSString *value = [self stringFromObject:dictionary[key]];
        if (value.length > 0) {
            return value;
        }
    }
    return nil;
}

- (NSString *)formattedPrice:(NSDecimalNumber *)price currency:(NSString *)currency {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;
    formatter.currencyCode = currency.length ? currency : @"USD";
    return [formatter stringFromNumber:price] ?: [NSString stringWithFormat:@"$%@", price];
}

- (NSDecimalNumber *)decimalFromObject:(id)object {
    if ([object isKindOfClass:[NSNumber class]]) {
        return [NSDecimalNumber decimalNumberWithDecimal:[object decimalValue]];
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *clean = [(NSString *)object stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        clean = [[clean componentsSeparatedByCharactersInSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]] componentsJoinedByString:@""];
        if (clean.length > 0) {
            NSDecimalNumber *number = [NSDecimalNumber decimalNumberWithString:clean];
            if (![number isEqualToNumber:[NSDecimalNumber notANumber]]) {
                return number;
            }
        }
    }
    return nil;
}

- (NSString *)stringFromObject:(id)object {
    if ([object isKindOfClass:[NSString class]]) {
        return object;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)object stringValue];
    }
    return nil;
}

- (NSString *)configurationStringForKey:(NSString *)key {
    id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

- (void)installThriftBooksCookiesIfNeeded {
    NSString *resource = [self configurationStringForKey:@"BKPricingCookieResource"];
    if (resource.length == 0) {
        resource = @"ThriftBooksCookies";
    }
    NSString *path = [[NSBundle mainBundle] pathForResource:resource ofType:@"json"];
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    if (data.length == 0) {
        return;
    }
    id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:60.0 * 60.0 * 24.0 * 30.0];
    for (NSString *key in [(NSDictionary *)payload allKeys]) {
        NSString *value = [self stringFromObject:[(NSDictionary *)payload objectForKey:key]];
        if (value.length > 0) {
            NSDictionary *properties = @{
                NSHTTPCookieName: key,
                NSHTTPCookieValue: value,
                NSHTTPCookieDomain: @".thriftbooks.com",
                NSHTTPCookiePath: @"/",
                NSHTTPCookieSecure: @"TRUE",
                NSHTTPCookieExpires: expires
            };
            NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
            if (cookie) {
                [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:cookie];
            }
        }
    }
}

- (NSString *)normalizedISBN:(NSString *)isbn {
    return [[isbn componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
}

@end
