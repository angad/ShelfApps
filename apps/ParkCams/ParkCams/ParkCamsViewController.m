#import "ParkCamsViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

static NSString *PCDecodeHTML(NSString *value) {
    if (value.length == 0) return @"";
    NSMutableString *decoded = [value mutableCopy];
    NSDictionary *entities = @{
        @"&amp;": @"&",
        @"&quot;": @"\"",
        @"&#39;": @"'",
        @"&apos;": @"'",
        @"&lt;": @"<",
        @"&gt;": @">",
        @"&#x2F;": @"/",
        @"&#x2f;": @"/",
        @"&#x3A;": @":",
        @"&#x3a;": @":"
    };
    for (NSString *entity in entities) {
        [decoded replaceOccurrencesOfString:entity
                                  withString:entities[entity]
                                     options:0
                                       range:NSMakeRange(0, decoded.length)];
    }
    return decoded;
}

static NSString *PCAbsoluteURL(NSString *raw, NSString *base) {
    NSString *decoded = PCDecodeHTML(raw);
    if (decoded.length == 0) return nil;
    if ([decoded hasPrefix:@"//"]) return [@"https:" stringByAppendingString:decoded];
    if ([decoded hasPrefix:@"/"]) return [@"https://www.nps.gov" stringByAppendingString:decoded];
    if ([decoded hasPrefix:@"http://"] || [decoded hasPrefix:@"https://"]) return decoded;
    NSURL *baseURL = [NSURL URLWithString:base ?: @"https://www.nps.gov/"];
    return [[NSURL URLWithString:decoded relativeToURL:baseURL] absoluteString] ?: decoded;
}

static NSString *PCFirstRegexGroup(NSString *text, NSString *pattern) {
    if (text.length == 0) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [text substringWithRange:[match rangeAtIndex:1]];
}

static NSString *PCURLByAddingRefreshToken(NSString *url, NSString *key) {
    if (url.length == 0) return nil;
    NSString *separator = [url rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
    NSTimeInterval stamp = floor([[NSDate date] timeIntervalSince1970]);
    return [NSString stringWithFormat:@"%@%@%@=%.0f", url, separator, key ?: @"r", stamp];
}

static NSDate *PCDateFromHTTPHeader(NSString *value) {
    if (value.length == 0) return nil;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss zzz";
    return [formatter dateFromString:value];
}

static NSString *PCHeaderValue(NSURLResponse *response, NSString *headerName) {
    NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
    NSString *value = headers[headerName];
    if (value.length) return value;
    for (NSString *key in headers) {
        if ([[key lowercaseString] isEqualToString:[headerName lowercaseString]]) {
            return headers[key];
        }
    }
    return nil;
}

static BOOL PCResponseIsFreshEnough(NSURLResponse *response, NSTimeInterval maxAge) {
    NSDate *lastModified = PCDateFromHTTPHeader(PCHeaderValue(response, @"Last-Modified"));
    if (!lastModified) return YES;
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:lastModified];
    return age < 0 || age <= maxAge;
}

static NSString *PCStaleNoteForResponse(NSURLResponse *response, NSTimeInterval maxAge) {
    NSDate *lastModified = PCDateFromHTTPHeader(PCHeaderValue(response, @"Last-Modified"));
    if (!lastModified) return nil;
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:lastModified];
    if (age < 0 || age <= maxAge) return nil;
    NSInteger hours = MAX(1, (NSInteger)ceil(age / 3600.0));
    return [NSString stringWithFormat:@"Stale image: updated %ldh ago", (long)hours];
}

static UIImage *PCImageFromDataScaled(NSData *data, CGFloat maxPixelSize) {
    if (data.length == 0) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(MAX(64.0, maxPixelSize))
    };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!imageRef) return nil;
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    return image;
}

static NSData *PCJPEGDataForImage(UIImage *image, CGFloat quality) {
    if (!image) return nil;
    NSData *data = UIImageJPEGRepresentation(image, quality);
    return data.length ? data : UIImagePNGRepresentation(image);
}

static NSString * const PCSlideshowManifestCacheKey = @"RangerLensSlideshowManifestV3";
static NSString * const PCShowUnavailableFeedsKey = @"RangerLensShowUnavailableFeedsV1";
static NSString * const PCParkThumbnailMetadataKey = @"RangerLensParkThumbnailMetadataV1";
static NSTimeInterval const PCSlideshowManifestMaxAge = 6.0 * 60.0 * 60.0;
static NSTimeInterval const PCSlideshowImageMaxAge = 90.0;
static NSTimeInterval const PCStillFeedMaxAge = 4.0 * 60.0 * 60.0;
static NSTimeInterval const PCParkThumbnailMaxAge = 7.0 * 24.0 * 60.0 * 60.0;
static NSUInteger const PCGenericImageCacheLimit = 42;
static NSUInteger const PCSlideshowImageCacheLimit = 8;

@class PCCameraFeed;

@interface PCCameraPark : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *region;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *webcamURL;
@property (nonatomic, copy) NSString *heroImageURL;
@property (nonatomic, strong) NSArray *postImages;
@property (nonatomic, strong) NSArray *manifestFeeds;
@property (nonatomic) NSInteger feedCount;
@property (nonatomic) BOOL hasLiveVideo;

+ (instancetype)parkWithName:(NSString *)name code:(NSString *)code region:(NSString *)region category:(NSString *)category detail:(NSString *)detail webcamURL:(NSString *)webcamURL feedCount:(NSInteger)feedCount;
@end

@implementation PCCameraPark

+ (instancetype)parkWithName:(NSString *)name code:(NSString *)code region:(NSString *)region category:(NSString *)category detail:(NSString *)detail webcamURL:(NSString *)webcamURL feedCount:(NSInteger)feedCount {
    PCCameraPark *park = [[PCCameraPark alloc] init];
    park.name = name;
    park.code = code;
    park.region = region;
    park.category = category;
    park.detail = detail;
    park.webcamURL = webcamURL;
    park.feedCount = feedCount;
    park.hasLiveVideo = [code isEqualToString:@"yell"];
    return park;
}

@end

@interface PCCameraFeed : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *imageURL;
@property (nonatomic, copy) NSString *streamURL;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *availabilityNote;
@property (nonatomic) BOOL available;

+ (instancetype)feedWithTitle:(NSString *)title imageURL:(NSString *)imageURL streamURL:(NSString *)streamURL sourceURL:(NSString *)sourceURL kind:(NSString *)kind;
+ (instancetype)feedWithDictionary:(NSDictionary *)dictionary;

@end

@implementation PCCameraFeed

+ (instancetype)feedWithTitle:(NSString *)title imageURL:(NSString *)imageURL streamURL:(NSString *)streamURL sourceURL:(NSString *)sourceURL kind:(NSString *)kind {
    PCCameraFeed *feed = [[PCCameraFeed alloc] init];
    feed.title = title.length ? title : @"Webcam";
    feed.imageURL = imageURL;
    feed.streamURL = streamURL;
    feed.sourceURL = sourceURL;
    feed.kind = kind.length ? kind : @"Still";
    feed.available = YES;
    feed.availabilityNote = @"Available";
    return feed;
}

+ (instancetype)feedWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    PCCameraFeed *feed = [PCCameraFeed feedWithTitle:dictionary[@"title"]
                                           imageURL:dictionary[@"imageURL"]
                                          streamURL:dictionary[@"streamURL"]
                                          sourceURL:dictionary[@"sourceURL"]
                                               kind:dictionary[@"kind"]];
    feed.available = [dictionary[@"available"] respondsToSelector:@selector(boolValue)] ? [dictionary[@"available"] boolValue] : YES;
    feed.availabilityNote = dictionary[@"availabilityNote"] ?: (feed.available ? @"Available" : @"Unavailable right now");
    if (feed.imageURL.length == 0 && feed.streamURL.length == 0 && feed.sourceURL.length == 0) return nil;
    return feed;
}

@end

@interface PCParkPhoto : NSObject

@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *caption;
@property (nonatomic, copy) NSString *credit;

+ (instancetype)photoWithDictionary:(NSDictionary *)dictionary;

@end

@implementation PCParkPhoto

+ (instancetype)photoWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSString *url = dictionary[@"url"];
    if (url.length == 0) return nil;
    PCParkPhoto *photo = [[PCParkPhoto alloc] init];
    photo.url = url;
    photo.title = dictionary[@"title"] ?: @"";
    photo.caption = dictionary[@"caption"] ?: @"";
    photo.credit = dictionary[@"credit"] ?: @"";
    return photo;
}

@end

@interface PCCameraPark (Manifest)

+ (instancetype)parkWithDictionary:(NSDictionary *)dictionary;

@end

@implementation PCCameraPark (Manifest)

+ (instancetype)parkWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    PCCameraPark *park = [[PCCameraPark alloc] init];
    park.name = dictionary[@"name"] ?: @"";
    park.code = dictionary[@"code"] ?: @"";
    park.region = dictionary[@"region"] ?: @"";
    park.category = dictionary[@"category"] ?: @"Scenic";
    park.detail = dictionary[@"detail"] ?: @"";
    park.webcamURL = dictionary[@"webcamURL"] ?: @"";
    park.heroImageURL = dictionary[@"heroImageURL"] ?: @"";
    park.feedCount = [dictionary[@"feedCount"] integerValue];
    park.hasLiveVideo = [dictionary[@"hasLiveVideo"] boolValue];
    NSArray *photoDictionaries = [dictionary[@"postImages"] isKindOfClass:[NSArray class]] ? dictionary[@"postImages"] : @[];
    NSMutableArray *photos = [NSMutableArray arrayWithCapacity:photoDictionaries.count];
    for (NSDictionary *photoDictionary in photoDictionaries) {
        PCParkPhoto *photo = [PCParkPhoto photoWithDictionary:photoDictionary];
        if (photo) [photos addObject:photo];
    }
    if (photos.count == 0 && park.heroImageURL.length) {
        PCParkPhoto *fallback = [[PCParkPhoto alloc] init];
        fallback.url = park.heroImageURL;
        fallback.caption = park.detail;
        [photos addObject:fallback];
    }
    park.postImages = photos;
    NSArray *feedDictionaries = [dictionary[@"feeds"] isKindOfClass:[NSArray class]] ? dictionary[@"feeds"] : @[];
    NSMutableArray *feeds = [NSMutableArray arrayWithCapacity:feedDictionaries.count];
    for (NSDictionary *feedDictionary in feedDictionaries) {
        PCCameraFeed *feed = [PCCameraFeed feedWithDictionary:feedDictionary];
        if (feed) [feeds addObject:feed];
    }
    park.manifestFeeds = feeds;
    return park.name.length && park.code.length ? park : nil;
}

@end

@interface PCSlideshowItem : NSObject

@property (nonatomic, copy) NSString *parkCode;
@property (nonatomic, copy) NSString *parkName;
@property (nonatomic, copy) NSString *region;
@property (nonatomic, copy) NSString *feedTitle;
@property (nonatomic, copy) NSString *imageURL;

+ (instancetype)itemWithPark:(PCCameraPark *)park feed:(PCCameraFeed *)feed;
+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;

@end

@implementation PCSlideshowItem

+ (instancetype)itemWithPark:(PCCameraPark *)park feed:(PCCameraFeed *)feed {
    PCSlideshowItem *item = [[PCSlideshowItem alloc] init];
    item.parkCode = park.code;
    item.parkName = park.name;
    item.region = park.region;
    item.feedTitle = feed.title;
    item.imageURL = feed.imageURL;
    return item;
}

+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSString *imageURL = dictionary[@"imageURL"];
    NSString *parkName = dictionary[@"parkName"];
    if (imageURL.length == 0 || parkName.length == 0) return nil;
    PCSlideshowItem *item = [[PCSlideshowItem alloc] init];
    item.parkCode = dictionary[@"parkCode"] ?: @"";
    item.parkName = parkName;
    item.region = dictionary[@"region"] ?: @"";
    item.feedTitle = dictionary[@"feedTitle"] ?: @"Webcam";
    item.imageURL = imageURL;
    return item;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"parkCode": self.parkCode ?: @"",
        @"parkName": self.parkName ?: @"",
        @"region": self.region ?: @"",
        @"feedTitle": self.feedTitle ?: @"Webcam",
        @"imageURL": self.imageURL ?: @""
    };
}

@end

@interface PCImageLoader : NSObject

@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *imageCache;
@property (nonatomic, strong) NSMutableArray<NSString *> *imageCacheOrder;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *parkImageURLCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *parkImageCompletionQueues;
@property (nonatomic, strong) NSURL *parkThumbnailDirectoryURL;

+ (instancetype)sharedLoader;
- (void)loadImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion;
- (void)loadFreshImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion;
- (void)loadParkImageForCode:(NSString *)code completion:(void (^)(UIImage *image))completion;
- (void)loadParkImageForCode:(NSString *)code imageURL:(NSString *)imageURL completion:(void (^)(UIImage *image))completion;
- (void)clearMemoryCache;

@end

@implementation PCImageLoader

+ (instancetype)sharedLoader {
    static PCImageLoader *loader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loader = [[PCImageLoader alloc] init];
        loader.imageCache = [NSMutableDictionary dictionary];
        loader.imageCacheOrder = [NSMutableArray array];
        loader.parkImageURLCache = [NSMutableDictionary dictionary];
        loader.parkImageCompletionQueues = [NSMutableDictionary dictionary];
    });
    return loader;
}

- (void)loadImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion {
    if (url.length == 0) {
        if (completion) completion(nil);
        return;
    }
    UIImage *cached = self.imageCache[url];
    if (cached) {
        if (completion) completion(cached);
        return;
    }
    NSURL *requestURL = [NSURL URLWithString:url];
    if (!requestURL) {
        if (completion) completion(nil);
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithURL:requestURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = PCImageFromDataScaled(data, 900.0);
        if (image) {
            @synchronized (self) {
                self.imageCache[url] = image;
                [self.imageCacheOrder removeObject:url];
                [self.imageCacheOrder addObject:url];
                while (self.imageCacheOrder.count > PCGenericImageCacheLimit) {
                    NSString *oldestURL = self.imageCacheOrder.firstObject;
                    [self.imageCache removeObjectForKey:oldestURL];
                    [self.imageCacheOrder removeObjectAtIndex:0];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(image);
        });
    }] resume];
}

- (void)loadFreshImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion {
    NSString *freshURL = PCURLByAddingRefreshToken(url, @"rangerlens");
    NSURL *requestURL = [NSURL URLWithString:freshURL];
    if (!requestURL) {
        if (completion) completion(nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:14.0];
    [request setValue:@"RangerLens" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = PCImageFromDataScaled(data, 900.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(image);
        });
    }] resume];
}

- (void)loadParkImageForCode:(NSString *)code completion:(void (^)(UIImage *image))completion {
    [self loadParkImageForCode:code imageURL:nil completion:completion];
}

- (void)loadParkImageForCode:(NSString *)code imageURL:(NSString *)imageURL completion:(void (^)(UIImage *image))completion {
    if (code.length == 0) {
        if (completion) completion(nil);
        return;
    }

    NSString *memoryKey = [NSString stringWithFormat:@"park-thumb:%@", code];
    UIImage *memoryImage = nil;
    @synchronized (self) {
        memoryImage = self.imageCache[memoryKey];
    }
    if (memoryImage && [self isParkThumbnailFreshForCode:code imageURL:imageURL]) {
        if (completion) completion(memoryImage);
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        BOOL isFresh = NO;
        UIImage *diskImage = [strongSelf cachedParkThumbnailForCode:code imageURL:imageURL fresh:&isFresh];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (!innerSelf) return;
            if (diskImage) {
                @synchronized (innerSelf) {
                    innerSelf.imageCache[memoryKey] = diskImage;
                }
                if (completion) completion(diskImage);
                if (isFresh) return;
            }
            [innerSelf refreshParkImageForCode:code preferredURL:imageURL completion:completion];
        });
    });
}

- (NSURL *)parkThumbnailDirectoryURL {
    if (_parkThumbnailDirectoryURL) return _parkThumbnailDirectoryURL;
    NSURL *cachesURL = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    _parkThumbnailDirectoryURL = [cachesURL URLByAppendingPathComponent:@"ParkThumbnails" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:_parkThumbnailDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    return _parkThumbnailDirectoryURL;
}

- (NSURL *)parkThumbnailFileURLForCode:(NSString *)code {
    return [self.parkThumbnailDirectoryURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.img", code]];
}

- (NSMutableDictionary *)parkThumbnailMetadata {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PCParkThumbnailMetadataKey];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

- (BOOL)isParkThumbnailFreshForCode:(NSString *)code imageURL:(NSString *)imageURL {
    NSDictionary *metadata = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PCParkThumbnailMetadataKey][code];
    NSNumber *timestamp = metadata[@"timestamp"];
    if (![timestamp isKindOfClass:[NSNumber class]]) return NO;
    NSString *storedURL = metadata[@"imageURL"];
    if (imageURL.length && storedURL.length && ![storedURL isEqualToString:imageURL]) return NO;
    return ([[NSDate date] timeIntervalSince1970] - [timestamp doubleValue]) < PCParkThumbnailMaxAge;
}

- (UIImage *)cachedParkThumbnailForCode:(NSString *)code imageURL:(NSString *)imageURL fresh:(BOOL *)fresh {
    if (fresh) *fresh = [self isParkThumbnailFreshForCode:code imageURL:imageURL];
    NSURL *fileURL = [self parkThumbnailFileURLForCode:code];
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    return PCImageFromDataScaled(data, 900.0);
}

- (void)saveParkThumbnailImage:(UIImage *)image imageURL:(NSString *)imageURL code:(NSString *)code {
    NSData *data = PCJPEGDataForImage(image, 0.84);
    if (data.length == 0 || code.length == 0) return;
    NSURL *fileURL = [self parkThumbnailFileURLForCode:code];
    [data writeToURL:fileURL atomically:YES];

    NSMutableDictionary *metadata = [self parkThumbnailMetadata];
    metadata[code] = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"imageURL": imageURL ?: @""
    };
    [[NSUserDefaults standardUserDefaults] setObject:metadata forKey:PCParkThumbnailMetadataKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)addParkImageCompletion:(void (^)(UIImage *image))completion forCode:(NSString *)code {
    @synchronized (self) {
        NSMutableArray *queue = self.parkImageCompletionQueues[code];
        if (queue) {
            if (completion) [queue addObject:[completion copy]];
            return NO;
        }
        queue = [NSMutableArray array];
        if (completion) [queue addObject:[completion copy]];
        self.parkImageCompletionQueues[code] = queue;
        return YES;
    }
}

- (void)finishParkImageLoadForCode:(NSString *)code image:(UIImage *)image {
    NSArray *callbacks = nil;
    @synchronized (self) {
        callbacks = [self.parkImageCompletionQueues[code] copy];
        [self.parkImageCompletionQueues removeObjectForKey:code];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id callback in callbacks) {
            void (^block)(UIImage *) = callback;
            if (block) block(image);
        }
    });
}

- (void)clearMemoryCache {
    @synchronized (self) {
        [self.imageCache removeAllObjects];
        [self.imageCacheOrder removeAllObjects];
        [self.parkImageURLCache removeAllObjects];
    }
}

- (void)refreshParkImageForCode:(NSString *)code preferredURL:(NSString *)preferredURL completion:(void (^)(UIImage *image))completion {
    if (![self addParkImageCompletion:completion forCode:code]) return;

    if (preferredURL.length) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:preferredURL]];
        request.timeoutInterval = 14.0;
        [request setValue:@"RangerLens" forHTTPHeaderField:@"User-Agent"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *imageData, NSURLResponse *imageResponse, NSError *imageError) {
            UIImage *image = PCImageFromDataScaled(imageData, 900.0);
            if (image) {
                NSString *memoryKey = [NSString stringWithFormat:@"park-thumb:%@", code];
                @synchronized (self) {
                    self.imageCache[memoryKey] = image;
                    self.parkImageURLCache[code] = preferredURL;
                }
                [self saveParkThumbnailImage:image imageURL:preferredURL code:code];
            }
            [self finishParkImageLoadForCode:code image:image];
        }] resume];
        return;
    }

    NSString *homeURL = [NSString stringWithFormat:@"https://www.nps.gov/%@/index.htm", code];
    NSURL *url = [NSURL URLWithString:homeURL];
    if (!url) {
        [self finishParkImageLoadForCode:code image:nil];
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *imageURL = PCFirstRegexGroup(html, @"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']");
        imageURL = PCAbsoluteURL(imageURL, homeURL);
        if (imageURL.length == 0) {
            [self finishParkImageLoadForCode:code image:nil];
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:imageURL]];
        request.timeoutInterval = 14.0;
        [request setValue:@"RangerLens" forHTTPHeaderField:@"User-Agent"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *imageData, NSURLResponse *imageResponse, NSError *imageError) {
            UIImage *image = PCImageFromDataScaled(imageData, 900.0);
            if (image) {
                NSString *memoryKey = [NSString stringWithFormat:@"park-thumb:%@", code];
                @synchronized (self) {
                    self.imageCache[memoryKey] = image;
                    self.parkImageURLCache[code] = imageURL;
                }
                [self saveParkThumbnailImage:image imageURL:imageURL code:code];
            }
            [self finishParkImageLoadForCode:code image:image];
        }] resume];
    }] resume];
}

@end

@interface PCParkImageView : UIImageView

@property (nonatomic, copy) NSString *paletteKey;

@end

@implementation PCParkImageView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentMode = UIViewContentModeScaleAspectFill;
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.18 blue:0.18 alpha:1.0];
    }
    return self;
}

- (void)setPaletteKey:(NSString *)paletteKey {
    _paletteKey = [paletteKey copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (self.image) {
        [super drawRect:rect];
        return;
    }
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIColor *top = [UIColor colorWithRed:0.12 green:0.34 blue:0.34 alpha:1.0];
    UIColor *bottom = [UIColor colorWithRed:0.05 green:0.12 blue:0.12 alpha:1.0];
    if ([self.paletteKey isEqualToString:@"desert"]) {
        top = [UIColor colorWithRed:0.62 green:0.28 blue:0.16 alpha:1.0];
        bottom = [UIColor colorWithRed:0.24 green:0.12 blue:0.08 alpha:1.0];
    } else if ([self.paletteKey isEqualToString:@"alpine"]) {
        top = [UIColor colorWithRed:0.14 green:0.34 blue:0.50 alpha:1.0];
        bottom = [UIColor colorWithRed:0.05 green:0.12 blue:0.18 alpha:1.0];
    } else if ([self.paletteKey isEqualToString:@"forest"]) {
        top = [UIColor colorWithRed:0.10 green:0.31 blue:0.23 alpha:1.0];
        bottom = [UIColor colorWithRed:0.04 green:0.14 blue:0.08 alpha:1.0];
    } else if ([self.paletteKey isEqualToString:@"coast"]) {
        top = [UIColor colorWithRed:0.08 green:0.39 blue:0.48 alpha:1.0];
        bottom = [UIColor colorWithRed:0.04 green:0.16 blue:0.22 alpha:1.0];
    }
    NSArray *colors = @[(__bridge id)top.CGColor, (__bridge id)bottom.CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat locations[] = {0.0, 1.0};
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, 0), CGPointMake(0, rect.size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(0, rect.size.height * 0.78)];
    [path addLineToPoint:CGPointMake(rect.size.width * 0.24, rect.size.height * 0.45)];
    [path addLineToPoint:CGPointMake(rect.size.width * 0.44, rect.size.height * 0.72)];
    [path addLineToPoint:CGPointMake(rect.size.width * 0.67, rect.size.height * 0.38)];
    [path addLineToPoint:CGPointMake(rect.size.width, rect.size.height * 0.73)];
    [path addLineToPoint:CGPointMake(rect.size.width, rect.size.height)];
    [path addLineToPoint:CGPointMake(0, rect.size.height)];
    [path closePath];
    [[UIColor colorWithWhite:0.0 alpha:0.24] setFill];
    [path fill];
}

@end

@interface PCCameraCell : UITableViewCell

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) PCParkImageView *parkImageView;
@property (nonatomic, strong) UIView *liveBadgeView;
@property (nonatomic, strong) UIView *liveDotView;
@property (nonatomic, strong) UILabel *liveLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *regionLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *categoryLabel;
@property (nonatomic, copy) NSString *representedCode;

- (void)configureWithPark:(PCCameraPark *)park;

@end

@implementation PCCameraCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.cardView = [[UIView alloc] init];
        self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
        self.cardView.backgroundColor = [UIColor colorWithRed:0.08 green:0.13 blue:0.13 alpha:1.0];
        self.cardView.layer.cornerRadius = 8.0;
        self.cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        self.cardView.layer.borderWidth = 1.0;
        self.cardView.clipsToBounds = YES;
        [self.contentView addSubview:self.cardView];

        self.parkImageView = [[PCParkImageView alloc] init];
        self.parkImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.cardView addSubview:self.parkImageView];

        UIView *shade = [[UIView alloc] init];
        shade.translatesAutoresizingMaskIntoConstraints = NO;
        shade.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.26];
        [self.parkImageView addSubview:shade];

        self.liveBadgeView = [[UIView alloc] init];
        self.liveBadgeView.translatesAutoresizingMaskIntoConstraints = NO;
        self.liveBadgeView.backgroundColor = [UIColor colorWithRed:0.95 green:0.24 blue:0.16 alpha:0.94];
        self.liveBadgeView.layer.cornerRadius = 10.0;
        self.liveBadgeView.clipsToBounds = YES;
        self.liveBadgeView.hidden = YES;
        [self.parkImageView addSubview:self.liveBadgeView];

        self.liveDotView = [[UIView alloc] init];
        self.liveDotView.translatesAutoresizingMaskIntoConstraints = NO;
        self.liveDotView.backgroundColor = [UIColor whiteColor];
        self.liveDotView.layer.cornerRadius = 3.0;
        [self.liveBadgeView addSubview:self.liveDotView];

        self.liveLabel = [PCCameraCell labelWithSize:9.0 weight:UIFontWeightBlack color:[UIColor whiteColor]];
        self.liveLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.liveLabel.text = @"LIVE";
        [self.liveBadgeView addSubview:self.liveLabel];

        self.regionLabel = [PCCameraCell labelWithSize:11.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0]];
        self.nameLabel = [PCCameraCell labelWithSize:22.0 weight:UIFontWeightBlack color:[UIColor whiteColor]];
        self.detailLabel = [PCCameraCell labelWithSize:13.0 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.74 alpha:1.0]];
        self.categoryLabel = [PCCameraCell labelWithSize:10.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:0.78 green:0.94 blue:0.84 alpha:1.0]];
        self.countLabel = [PCCameraCell labelWithSize:12.0 weight:UIFontWeightBlack color:[UIColor colorWithWhite:0.96 alpha:1.0]];

        self.regionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.nameLabel.minimumScaleFactor = 0.75;
        self.nameLabel.adjustsFontSizeToFitWidth = YES;
        self.nameLabel.numberOfLines = 1;
        self.detailLabel.numberOfLines = 2;
        self.categoryLabel.textAlignment = NSTextAlignmentCenter;
        self.categoryLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        self.categoryLabel.layer.cornerRadius = 4.0;
        self.categoryLabel.clipsToBounds = YES;
        self.countLabel.textAlignment = NSTextAlignmentRight;

        for (UIView *view in @[self.regionLabel, self.nameLabel, self.detailLabel, self.categoryLabel, self.countLabel]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.cardView addSubview:view];
        }

        [NSLayoutConstraint activateConstraints:@[
            [self.cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12.0],
            [self.cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],
            [self.cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:7.0],
            [self.cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-7.0],

            [self.parkImageView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
            [self.parkImageView.topAnchor constraintEqualToAnchor:self.cardView.topAnchor],
            [self.parkImageView.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor],
            [self.parkImageView.widthAnchor constraintEqualToConstant:126.0],
            [shade.leadingAnchor constraintEqualToAnchor:self.parkImageView.leadingAnchor],
            [shade.trailingAnchor constraintEqualToAnchor:self.parkImageView.trailingAnchor],
            [shade.topAnchor constraintEqualToAnchor:self.parkImageView.topAnchor],
            [shade.bottomAnchor constraintEqualToAnchor:self.parkImageView.bottomAnchor],

            [self.liveBadgeView.leadingAnchor constraintEqualToAnchor:self.parkImageView.leadingAnchor constant:8.0],
            [self.liveBadgeView.topAnchor constraintEqualToAnchor:self.parkImageView.topAnchor constant:8.0],
            [self.liveBadgeView.widthAnchor constraintEqualToConstant:48.0],
            [self.liveBadgeView.heightAnchor constraintEqualToConstant:20.0],
            [self.liveDotView.leadingAnchor constraintEqualToAnchor:self.liveBadgeView.leadingAnchor constant:8.0],
            [self.liveDotView.centerYAnchor constraintEqualToAnchor:self.liveBadgeView.centerYAnchor],
            [self.liveDotView.widthAnchor constraintEqualToConstant:6.0],
            [self.liveDotView.heightAnchor constraintEqualToConstant:6.0],
            [self.liveLabel.leadingAnchor constraintEqualToAnchor:self.liveDotView.trailingAnchor constant:5.0],
            [self.liveLabel.centerYAnchor constraintEqualToAnchor:self.liveBadgeView.centerYAnchor],

            [self.regionLabel.leadingAnchor constraintEqualToAnchor:self.parkImageView.trailingAnchor constant:12.0],
            [self.regionLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-14.0],
            [self.regionLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:12.0],

            [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.regionLabel.leadingAnchor],
            [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.regionLabel.trailingAnchor],
            [self.nameLabel.topAnchor constraintEqualToAnchor:self.regionLabel.bottomAnchor constant:2.0],

            [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.regionLabel.leadingAnchor],
            [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.regionLabel.trailingAnchor],
            [self.detailLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:3.0],
            [self.detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.categoryLabel.topAnchor constant:-6.0],

            [self.categoryLabel.leadingAnchor constraintEqualToAnchor:self.regionLabel.leadingAnchor],
            [self.categoryLabel.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor constant:-11.0],
            [self.categoryLabel.widthAnchor constraintEqualToConstant:82.0],
            [self.categoryLabel.heightAnchor constraintEqualToConstant:24.0],

            [self.countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.categoryLabel.trailingAnchor constant:8.0],
            [self.countLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-14.0],
            [self.countLabel.centerYAnchor constraintEqualToAnchor:self.categoryLabel.centerYAnchor]
        ]];
    }
    return self;
}

+ (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.parkImageView.image = nil;
    [self.parkImageView setNeedsDisplay];
    self.liveBadgeView.hidden = YES;
    self.representedCode = nil;
}

- (void)configureWithPark:(PCCameraPark *)park {
    self.representedCode = park.code;
    self.parkImageView.paletteKey = [self paletteForCategory:park.category];
    self.regionLabel.text = [park.region uppercaseString];
    self.nameLabel.text = park.name;
    self.detailLabel.text = park.detail;
    self.categoryLabel.text = [park.category uppercaseString];
    self.countLabel.text = park.feedCount == 1 ? @"1 feed" : [NSString stringWithFormat:@"%ld feeds", (long)park.feedCount];
    self.liveBadgeView.hidden = !park.hasLiveVideo;

    [[PCImageLoader sharedLoader] loadParkImageForCode:park.code imageURL:park.heroImageURL completion:^(UIImage *image) {
        if (image && [self.representedCode isEqualToString:park.code]) {
            self.parkImageView.image = image;
        }
    }];
}

- (NSString *)paletteForCategory:(NSString *)category {
    if ([category isEqualToString:@"Water"] || [category isEqualToString:@"Coast"]) return @"coast";
    if ([category isEqualToString:@"Wildlife"]) return @"forest";
    if ([category isEqualToString:@"Volcano"]) return @"desert";
    return @"alpine";
}

@end

@interface PCFeedCell : UITableViewCell

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) PCParkImageView *thumbView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *kindLabel;
@property (nonatomic, strong) UILabel *noteLabel;
@property (nonatomic, copy) NSString *representedImageURL;

- (void)configureWithFeed:(PCCameraFeed *)feed;

@end

@implementation PCFeedCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.cardView = [[UIView alloc] init];
        self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
        self.cardView.backgroundColor = [UIColor colorWithRed:0.08 green:0.13 blue:0.13 alpha:1.0];
        self.cardView.layer.cornerRadius = 8.0;
        self.cardView.layer.borderWidth = 1.0;
        self.cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        self.cardView.clipsToBounds = YES;
        [self.contentView addSubview:self.cardView];

        self.thumbView = [[PCParkImageView alloc] init];
        self.thumbView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.cardView addSubview:self.thumbView];

        self.titleLabel = [PCCameraCell labelWithSize:17.0 weight:UIFontWeightBlack color:[UIColor whiteColor]];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.numberOfLines = 2;
        [self.cardView addSubview:self.titleLabel];

        self.kindLabel = [PCCameraCell labelWithSize:11.0 weight:UIFontWeightBlack color:[UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0]];
        self.kindLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.cardView addSubview:self.kindLabel];

        self.noteLabel = [PCCameraCell labelWithSize:12.0 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.70 alpha:1.0]];
        self.noteLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.noteLabel.numberOfLines = 2;
        self.noteLabel.hidden = YES;
        [self.cardView addSubview:self.noteLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12.0],
            [self.cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],
            [self.cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6.0],
            [self.cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6.0],
            [self.thumbView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
            [self.thumbView.topAnchor constraintEqualToAnchor:self.cardView.topAnchor],
            [self.thumbView.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor],
            [self.thumbView.widthAnchor constraintEqualToConstant:118.0],
            [self.kindLabel.leadingAnchor constraintEqualToAnchor:self.thumbView.trailingAnchor constant:12.0],
            [self.kindLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-12.0],
            [self.kindLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:12.0],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.kindLabel.leadingAnchor],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.kindLabel.trailingAnchor],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.kindLabel.bottomAnchor constant:5.0],
            [self.noteLabel.leadingAnchor constraintEqualToAnchor:self.kindLabel.leadingAnchor],
            [self.noteLabel.trailingAnchor constraintEqualToAnchor:self.kindLabel.trailingAnchor],
            [self.noteLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:3.0],
            [self.noteLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.cardView.bottomAnchor constant:-8.0]
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.thumbView.image = nil;
    self.thumbView.alpha = 1.0;
    self.cardView.backgroundColor = [UIColor colorWithRed:0.08 green:0.13 blue:0.13 alpha:1.0];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.kindLabel.textColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0];
    self.noteLabel.hidden = YES;
    self.noteLabel.text = nil;
    self.representedImageURL = nil;
}

- (void)configureWithFeed:(PCCameraFeed *)feed {
    self.titleLabel.text = feed.title;
    self.kindLabel.text = feed.available ? [feed.kind uppercaseString] : @"FILTERED";
    self.representedImageURL = feed.imageURL;
    self.thumbView.paletteKey = @"alpine";

    if (!feed.available) {
        self.cardView.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.09 alpha:1.0];
        self.thumbView.alpha = 0.42;
        self.titleLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
        self.kindLabel.textColor = [UIColor colorWithRed:1.0 green:0.47 blue:0.38 alpha:1.0];
        self.noteLabel.text = feed.availabilityNote.length ? feed.availabilityNote : @"Unavailable right now";
        self.noteLabel.hidden = NO;
        return;
    }

    [[PCImageLoader sharedLoader] loadFreshImageAtURL:feed.imageURL completion:^(UIImage *image) {
        if (image && [self.representedImageURL isEqualToString:feed.imageURL]) {
            self.thumbView.image = image;
        }
    }];
}

@end

@interface PCFeedViewController : UIViewController

@property (nonatomic, strong) PCCameraFeed *feed;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) AVPlayerViewController *playerController;

- (instancetype)initWithFeed:(PCCameraFeed *)feed;

@end

@implementation PCFeedViewController

- (instancetype)initWithFeed:(PCCameraFeed *)feed {
    self = [super init];
    if (self) {
        self.feed = feed;
        self.title = feed.title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.08 alpha:1.0];

    if (self.feed.streamURL.length) {
        NSURL *url = [NSURL URLWithString:self.feed.streamURL];
        AVPlayer *player = [AVPlayer playerWithURL:url];
        self.playerController = [[AVPlayerViewController alloc] init];
        self.playerController.player = player;
        [self addChildViewController:self.playerController];
        self.playerController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.playerController.view];
        [self.playerController didMoveToParentViewController:self];
        [NSLayoutConstraint activateConstraints:@[
            [self.playerController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.playerController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.playerController.view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
            [self.playerController.view.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
        ]];
        [player play];
        return;
    }

    self.imageView = [[UIImageView alloc] init];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.backgroundColor = [UIColor blackColor];
    [self.view addSubview:self.imageView];

    UIView *footer = [[UIView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.backgroundColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.13 alpha:1.0];
    [self.view addSubview:footer];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"Refreshing latest still image every 60 seconds.";
    [footer addSubview:self.statusLabel];

    UIButton *refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [refreshButton setTitle:@"Refresh" forState:UIControlStateNormal];
    refreshButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBlack];
    [refreshButton setTitleColor:[UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0] forState:UIControlStateNormal];
    [refreshButton addTarget:self action:@selector(loadStillImage) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:refreshButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.imageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:82.0],
        [self.imageView.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16.0],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:refreshButton.leadingAnchor constant:-12.0],
        [refreshButton.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16.0],
        [refreshButton.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [refreshButton.widthAnchor constraintEqualToConstant:78.0]
    ]];

    [self loadStillImage];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:60.0 target:self selector:@selector(loadStillImage) userInfo:nil repeats:YES];
}

- (void)dealloc {
    [self.timer invalidate];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    self.imageView.image = nil;
}

- (void)loadStillImage {
    NSString *url = self.feed.imageURL;
    if (url.length == 0) return;
    NSString *cacheBusted = PCURLByAddingRefreshToken(url, @"rangerlens");
    NSURL *requestURL = [NSURL URLWithString:cacheBusted];
    self.statusLabel.text = @"Loading latest image...";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:14.0];
    [request setValue:@"RangerLens" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = PCImageFromDataScaled(data, 1600.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) {
                self.imageView.image = image;
                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                formatter.timeStyle = NSDateFormatterShortStyle;
                self.statusLabel.text = [NSString stringWithFormat:@"Latest image loaded %@", [formatter stringFromDate:[NSDate date]]];
            } else {
                self.statusLabel.text = @"Image unavailable right now.";
            }
        });
    }] resume];
}

@end

@interface PCFeedListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) PCCameraPark *park;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *showUnavailableLabel;
@property (nonatomic, strong) UISwitch *showUnavailableSwitch;
@property (nonatomic, strong) NSArray<PCCameraFeed *> *feeds;
@property (nonatomic, strong) NSArray<PCCameraFeed *> *validatedFeeds;

- (instancetype)initWithPark:(PCCameraPark *)park;
- (void)validateFeeds:(NSArray<PCCameraFeed *> *)feeds completion:(void (^)(NSArray<PCCameraFeed *> *validFeeds))completion;
- (void)validateFeeds:(NSArray<PCCameraFeed *> *)feeds includeUnavailable:(BOOL)includeUnavailable completion:(void (^)(NSArray<PCCameraFeed *> *displayFeeds))completion;
- (NSArray<PCCameraFeed *> *)parseFeedsFromHTML:(NSString *)html baseURL:(NSString *)baseURL;

@end

@implementation PCFeedListViewController

- (instancetype)initWithPark:(PCCameraPark *)park {
    self = [super init];
    if (self) {
        self.park = park;
        self.title = park.name;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.08 alpha:1.0];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.80 alpha:1.0];
    self.statusLabel.text = @"Finding direct camera feeds...";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    UIView *optionsView = [[UIView alloc] init];
    optionsView.translatesAutoresizingMaskIntoConstraints = NO;
    optionsView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    [self.view addSubview:optionsView];

    self.showUnavailableLabel = [[UILabel alloc] init];
    self.showUnavailableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.showUnavailableLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
    self.showUnavailableLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    self.showUnavailableLabel.text = @"Show filtered feeds";
    [optionsView addSubview:self.showUnavailableLabel];

    self.showUnavailableSwitch = [[UISwitch alloc] init];
    self.showUnavailableSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.showUnavailableSwitch.onTintColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0];
    self.showUnavailableSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:PCShowUnavailableFeedsKey];
    [self.showUnavailableSwitch addTarget:self action:@selector(showUnavailableChanged:) forControlEvents:UIControlEventValueChanged];
    [optionsView addSubview:self.showUnavailableSwitch];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 108.0;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[PCFeedCell class] forCellReuseIdentifier:@"FeedCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12.0],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8.0],
        [self.statusLabel.heightAnchor constraintEqualToConstant:24.0],
        [optionsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [optionsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [optionsView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:4.0],
        [optionsView.heightAnchor constraintEqualToConstant:42.0],
        [self.showUnavailableLabel.leadingAnchor constraintEqualToAnchor:optionsView.leadingAnchor constant:18.0],
        [self.showUnavailableLabel.centerYAnchor constraintEqualToAnchor:optionsView.centerYAnchor],
        [self.showUnavailableSwitch.trailingAnchor constraintEqualToAnchor:optionsView.trailingAnchor constant:-18.0],
        [self.showUnavailableSwitch.centerYAnchor constraintEqualToAnchor:optionsView.centerYAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:optionsView.bottomAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [self loadFeeds];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [[PCImageLoader sharedLoader] clearMemoryCache];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.feeds.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PCFeedCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FeedCell" forIndexPath:indexPath];
    [cell configureWithFeed:self.feeds[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PCCameraFeed *feed = self.feeds[indexPath.row];
    if (!feed.available) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Filtered feed"
                                                                       message:feed.availabilityNote.length ? feed.availabilityNote : @"This feed is unavailable right now."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    PCFeedViewController *viewer = [[PCFeedViewController alloc] initWithFeed:feed];
    [self.navigationController pushViewController:viewer animated:YES];
}

- (void)showUnavailableChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:PCShowUnavailableFeedsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self applyFeedVisibility];
}

- (void)applyFeedVisibility {
    NSMutableArray<PCCameraFeed *> *displayFeeds = [NSMutableArray array];
    NSInteger available = 0;
    NSInteger filtered = 0;
    for (PCCameraFeed *feed in self.validatedFeeds) {
        if (feed.available) {
            available++;
            [displayFeeds addObject:feed];
        } else {
            filtered++;
            if (self.showUnavailableSwitch.on) [displayFeeds addObject:feed];
        }
    }
    self.feeds = displayFeeds;
    if (self.showUnavailableSwitch.on) {
        self.statusLabel.text = [NSString stringWithFormat:@"%ld working  |  %ld filtered", (long)available, (long)filtered];
    } else if (filtered > 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"%ld working native feeds  |  %ld hidden", (long)available, (long)filtered];
    } else {
        self.statusLabel.text = available == 1 ? @"1 working native feed" : [NSString stringWithFormat:@"%ld working native feeds", (long)available];
    }
    if (available == 0 && filtered == 0) self.statusLabel.text = @"No direct feeds found for this page.";
    [self.tableView reloadData];
}

- (void)loadFeeds {
    if (self.park.manifestFeeds.count) {
        NSArray<PCCameraFeed *> *feeds = self.park.manifestFeeds;
        self.statusLabel.text = @"Loaded API-validated feeds.";
        self.validatedFeeds = feeds;
        [self applyFeedVisibility];
        return;
    }

    NSURL *url = [NSURL URLWithString:self.park.webcamURL];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSArray<PCCameraFeed *> *feeds = [self parseFeedsFromHTML:html baseURL:self.park.webcamURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = feeds.count == 1 ? @"Testing 1 direct feed..." : [NSString stringWithFormat:@"Testing %ld direct feeds...", (long)feeds.count];
        });
        [self validateFeeds:feeds includeUnavailable:YES completion:^(NSArray<PCCameraFeed *> *validatedFeeds) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.validatedFeeds = validatedFeeds;
                [self applyFeedVisibility];
            });
        }];
    }] resume];
}

- (void)validateFeeds:(NSArray<PCCameraFeed *> *)feeds completion:(void (^)(NSArray<PCCameraFeed *> *validFeeds))completion {
    [self validateFeeds:feeds includeUnavailable:NO completion:completion];
}

- (void)validateFeeds:(NSArray<PCCameraFeed *> *)feeds includeUnavailable:(BOOL)includeUnavailable completion:(void (^)(NSArray<PCCameraFeed *> *displayFeeds))completion {
    if (feeds.count == 0) {
        if (completion) completion(@[]);
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSNumber *, PCCameraFeed *> *feedsByIndex = [NSMutableDictionary dictionary];
    NSLock *lock = [[NSLock alloc] init];

    for (NSUInteger index = 0; index < feeds.count; index++) {
        PCCameraFeed *feed = feeds[index];
        feed.available = NO;
        feed.availabilityNote = @"Not tested";
        NSString *urlString = feed.streamURL.length ? feed.streamURL : feed.imageURL;
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            feed.availabilityNote = @"Invalid feed URL";
            if (includeUnavailable) {
                [lock lock];
                feedsByIndex[@(index)] = feed;
                [lock unlock];
            }
            continue;
        }

        dispatch_group_enter(group);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
        [request setValue:@"RangerLens" forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
        [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            BOOL isValid = NO;
            NSString *note = nil;
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (error) {
                note = error.localizedDescription ?: @"Network error";
            } else if (statusCode >= 400) {
                note = [NSString stringWithFormat:@"HTTP %ld", (long)statusCode];
            } else if (data.length == 0) {
                note = @"No image data returned";
            } else {
                if (feed.streamURL.length) {
                    NSString *playlist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    isValid = [playlist rangeOfString:@"#EXTM3U"].location != NSNotFound;
                    if (!isValid) note = @"Not an HLS playlist";
                } else {
                    UIImage *image = PCImageFromDataScaled(data, 900.0);
                    NSString *staleNote = PCStaleNoteForResponse(response, PCStillFeedMaxAge);
                    isValid = image != nil && staleNote.length == 0;
                    if (!image) {
                        note = @"Not image data";
                    } else if (staleNote.length) {
                        note = staleNote;
                    }
                }
            }
            feed.available = isValid;
            feed.availabilityNote = isValid ? @"Available" : (note.length ? note : @"Unavailable right now");
            if (isValid || includeUnavailable) {
                [lock lock];
                feedsByIndex[@(index)] = feed;
                [lock unlock];
            }
            dispatch_group_leave(group);
        }] resume];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<PCCameraFeed *> *orderedFeeds = [NSMutableArray array];
        NSArray<NSNumber *> *indexes = [[feedsByIndex allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *index in indexes) {
            [orderedFeeds addObject:feedsByIndex[index]];
        }
        if (completion) completion(orderedFeeds);
    });
}

- (NSArray<PCCameraFeed *> *)parseFeedsFromHTML:(NSString *)html baseURL:(NSString *)baseURL {
    if (html.length == 0) return @[];
    NSMutableArray<PCCameraFeed *> *feeds = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    NSString *directImage = PCFirstRegexGroup(html, @"id=[\"']webcamRefreshImage[\"'][^>]+src=[\"']([^\"']+)[\"']");
    if (directImage.length) {
        NSString *title = PCDecodeHTML(PCFirstRegexGroup(html, @"<h1[^>]*>(.*?)</h1>"));
        NSString *imageURL = PCAbsoluteURL(directImage, baseURL);
        [feeds addObject:[PCCameraFeed feedWithTitle:title imageURL:imageURL streamURL:nil sourceURL:baseURL kind:@"Still Webcam"]];
        [seen addObject:imageURL];
    }

    NSString *pixelCamera = PCFirstRegexGroup(html, @"data-camera=[\"']([^\"']+)[\"']");
    if (pixelCamera.length && [html rangeOfString:@"pixelcaster.com"].location != NSNotFound) {
        NSString *poster = PCFirstRegexGroup(html, @"poster:\\s*[\"']([^\"']+)[\"']");
        NSString *stream = [NSString stringWithFormat:@"https://cs7.pixelcaster.com/nps/%@.stream/playlist_dvr.m3u8", pixelCamera];
        NSString *imageURL = poster.length ? PCAbsoluteURL(poster, baseURL) : nil;
        [feeds addObject:[PCCameraFeed feedWithTitle:@"Old Faithful Live" imageURL:imageURL streamURL:stream sourceURL:baseURL kind:@"Live HLS"]];
        [seen addObject:stream];
    }

    NSRegularExpression *m3u8Regex = [NSRegularExpression regularExpressionWithPattern:@"(https?:)?//[^\"'\\s<>]+\\.m3u8[^\"'\\s<>]*" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *m3u8Matches = [m3u8Regex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *match in m3u8Matches) {
        NSString *stream = PCAbsoluteURL([html substringWithRange:match.range], baseURL);
        if (![seen containsObject:stream]) {
            [feeds addObject:[PCCameraFeed feedWithTitle:@"Live Stream" imageURL:nil streamURL:stream sourceURL:baseURL kind:@"Live HLS"]];
            [seen addObject:stream];
        }
    }

    NSRegularExpression *imgRegex = [NSRegularExpression regularExpressionWithPattern:@"<img[^>]+class=[\"'][^\"']*WebcamPreview__CoverImage[^\"']*[\"'][^>]*>" options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSArray *imgMatches = [imgRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *match in imgMatches) {
        NSString *tag = [html substringWithRange:match.range];
        NSString *src = PCFirstRegexGroup(tag, @"src=[\"']([^\"']+)[\"']");
        NSString *title = PCFirstRegexGroup(tag, @"title=[\"']([^\"']+)[\"']");
        if (title.length == 0) title = PCFirstRegexGroup(tag, @"alt=[\"']([^\"']+)[\"']");
        NSString *imageURL = PCAbsoluteURL(src, baseURL);
        if (imageURL.length == 0 || [seen containsObject:imageURL]) continue;
        if ([imageURL rangeOfString:@"inactive_webcam"].location != NSNotFound || [imageURL rangeOfString:@"placeholder"].location != NSNotFound || [imageURL hasSuffix:@".svg"]) continue;
        [feeds addObject:[PCCameraFeed feedWithTitle:PCDecodeHTML(title) imageURL:imageURL streamURL:nil sourceURL:baseURL kind:@"Still Webcam"]];
        [seen addObject:imageURL];
    }

    return feeds;
}

@end

static UIColor *PCSocialWhite(void) {
    return [UIColor colorWithWhite:1.0 alpha:1.0];
}

static UIColor *PCSocialText(void) {
    return [UIColor colorWithWhite:0.06 alpha:1.0];
}

static NSString *PCInitialsForPark(PCCameraPark *park) {
    NSMutableString *initials = [NSMutableString string];
    NSArray *words = [park.name componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *word in words) {
        if (word.length == 0) continue;
        NSString *lower = [word lowercaseString];
        if ([lower isEqualToString:@"and"] || [lower isEqualToString:@"the"]) continue;
        [initials appendString:[[word substringToIndex:1] uppercaseString]];
        if (initials.length >= 2) break;
    }
    return initials.length ? initials : @"NP";
}

static NSString *PCHandleForPark(PCCameraPark *park) {
    NSString *code = park.code.length ? [park.code lowercaseString] : @"park";
    return [NSString stringWithFormat:@"@nps_%@", code];
}

static NSArray<PCCameraFeed *> *PCAvailableFeedsForPark(PCCameraPark *park) {
    NSMutableArray<PCCameraFeed *> *feeds = [NSMutableArray array];
    NSMutableArray<PCCameraFeed *> *live = [NSMutableArray array];
    NSMutableArray<PCCameraFeed *> *stills = [NSMutableArray array];
    for (PCCameraFeed *feed in park.manifestFeeds) {
        if (!feed.available) continue;
        if (feed.streamURL.length) {
            [live addObject:feed];
        } else if (feed.imageURL.length) {
            [stills addObject:feed];
        }
    }
    [feeds addObjectsFromArray:live];
    [feeds addObjectsFromArray:stills];
    return feeds;
}

@interface PCSocialPost : NSObject

@property (nonatomic, strong) PCCameraPark *park;
@property (nonatomic, strong) PCParkPhoto *photo;

+ (instancetype)postWithPark:(PCCameraPark *)park photo:(PCParkPhoto *)photo;

@end

@implementation PCSocialPost

+ (instancetype)postWithPark:(PCCameraPark *)park photo:(PCParkPhoto *)photo {
    PCSocialPost *post = [[PCSocialPost alloc] init];
    post.park = park;
    post.photo = photo;
    return post;
}

@end

@interface PCSocialStoryMediaView : UIView

@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) AVPlayer *player;
- (void)configureWithImage:(UIImage *)image;
- (void)configureWithPlayer:(AVPlayer *)player;
- (void)stop;

@end

@implementation PCSocialStoryMediaView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.clipsToBounds = YES;
        self.imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds = YES;
        [self addSubview:self.imageView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}

- (void)configureWithImage:(UIImage *)image {
    [self stop];
    self.imageView.hidden = NO;
    self.imageView.image = image;
}

- (void)configureWithPlayer:(AVPlayer *)player {
    [self stop];
    self.player = player;
    self.imageView.hidden = YES;
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer insertSublayer:self.playerLayer atIndex:0];
}

- (void)stop {
    [self.player pause];
    [self.playerLayer removeFromSuperlayer];
    self.player = nil;
    self.playerLayer = nil;
}

@end

@interface PCSocialStoryViewController : UIViewController

@property (nonatomic, strong) PCCameraPark *park;
@property (nonatomic, copy) NSArray<PCCameraPark *> *parks;
@property (nonatomic, copy) NSArray<PCCameraFeed *> *feeds;
@property (nonatomic, strong) PCSocialStoryMediaView *mediaView;
@property (nonatomic, strong) UIView *progressContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *progressFills;
@property (nonatomic, strong) UILabel *parkLabel;
@property (nonatomic, strong) UILabel *feedLabel;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSInteger parkIndex;
@property (nonatomic) NSInteger currentIndex;
@property (nonatomic) BOOL hasDisplayedMedia;

- (instancetype)initWithPark:(PCCameraPark *)park feeds:(NSArray<PCCameraFeed *> *)feeds;
- (instancetype)initWithParks:(NSArray<PCCameraPark *> *)parks startIndex:(NSInteger)startIndex;

@end

@implementation PCSocialStoryViewController

- (instancetype)initWithPark:(PCCameraPark *)park feeds:(NSArray<PCCameraFeed *> *)feeds {
    return [self initWithParks:park ? @[park] : @[] startIndex:0];
}

- (instancetype)initWithParks:(NSArray<PCCameraPark *> *)parks startIndex:(NSInteger)startIndex {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        NSMutableArray *storyParks = [NSMutableArray array];
        for (PCCameraPark *park in parks ?: @[]) {
            if (PCAvailableFeedsForPark(park).count) [storyParks addObject:park];
        }
        self.parks = storyParks;
        self.parkIndex = MIN(MAX(0, startIndex), MAX(0, (NSInteger)storyParks.count - 1));
        self.currentIndex = -1;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    self.mediaView = [[PCSocialStoryMediaView alloc] initWithFrame:self.view.bounds];
    self.mediaView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.mediaView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mediaTapped:)];
    [self.mediaView addGestureRecognizer:tap];

    self.progressContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.progressContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.progressContainer];

    self.parkLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.parkLabel.textColor = [UIColor whiteColor];
    self.parkLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack];
    self.parkLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.9];
    self.parkLabel.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:self.parkLabel];

    self.feedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.feedLabel.textColor = [UIColor colorWithWhite:0.95 alpha:0.92];
    self.feedLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.feedLabel.adjustsFontSizeToFitWidth = YES;
    self.feedLabel.minimumScaleFactor = 0.72;
    self.feedLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    self.feedLabel.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:self.feedLabel];

    self.progressLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.progressLabel.textColor = [UIColor whiteColor];
    self.progressLabel.textAlignment = NSTextAlignmentRight;
    self.progressLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBlack];
    self.progressLabel.shadowColor = [UIColor blackColor];
    self.progressLabel.shadowOffset = CGSizeMake(0, 1);
    self.progressLabel.hidden = YES;
    [self.view addSubview:self.progressLabel];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"X" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBlack];
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    if (self.parks.count) {
        [self loadParkAtIndex:self.parkIndex startStoryIndex:0 forward:YES];
    } else {
        self.parkLabel.text = @"No story available";
        self.feedLabel.text = @"";
        self.progressLabel.text = @"";
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.mediaView.frame = self.view.bounds;
    CGFloat width = self.view.bounds.size.width;
    self.progressContainer.frame = CGRectMake(10.0, 14.0, width - 20.0, 4.0);
    [self layoutProgressSegments];
    self.closeButton.frame = CGRectMake(width - 56.0, 34.0, 44.0, 38.0);
    self.parkLabel.frame = CGRectMake(16.0, 38.0, width - 84.0, 24.0);
    self.feedLabel.frame = CGRectMake(16.0, 62.0, width - 86.0, 18.0);
    self.progressLabel.frame = CGRectMake(width - 92.0, self.view.bounds.size.height - 42.0, 72.0, 20.0);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self stopCurrentMedia];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)dealloc {
    [self stopCurrentMedia];
}

- (void)mediaTapped:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:self.view];
    if (point.x < self.view.bounds.size.width * 0.33) {
        [self showFeedAtIndex:self.currentIndex - 1 forward:NO];
    } else {
        [self showFeedAtIndex:self.currentIndex + 1 forward:YES];
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)stopCurrentMedia {
    [self.timer invalidate];
    self.timer = nil;
    for (UIView *fill in self.progressFills) {
        [fill.layer removeAllAnimations];
    }
    [self.mediaView stop];
}

- (void)scheduleAdvanceForFeed:(PCCameraFeed *)feed {
    [self.timer invalidate];
    NSTimeInterval interval = feed.streamURL.length ? 14.0 : 6.0;
    [self animateCurrentProgressForDuration:interval];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(nextStory) userInfo:nil repeats:NO];
}

- (void)nextStory {
    [self showFeedAtIndex:self.currentIndex + 1 forward:YES];
}

- (void)loadParkAtIndex:(NSInteger)parkIndex startStoryIndex:(NSInteger)storyIndex forward:(BOOL)forward {
    if (parkIndex < 0) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (parkIndex >= (NSInteger)self.parks.count) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.parkIndex = parkIndex;
    self.park = self.parks[parkIndex];
    NSArray<PCCameraFeed *> *feeds = PCAvailableFeedsForPark(self.park);
    self.feeds = feeds.count > 12 ? [feeds subarrayWithRange:NSMakeRange(0, 12)] : feeds;
    self.currentIndex = -1;
    self.parkLabel.text = self.park.name;
    self.progressLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)parkIndex + 1, (long)self.parks.count];
    [self buildProgressSegments];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    NSInteger index = storyIndex;
    if (index == NSIntegerMax) index = self.feeds.count - 1;
    [self showFeedAtIndex:index forward:forward];
}

- (void)buildProgressSegments {
    [self.progressContainer.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.progressFills = [NSMutableArray array];
    NSUInteger count = MAX((NSUInteger)1, self.feeds.count);
    for (NSUInteger index = 0; index < count; index++) {
        UIView *track = [[UIView alloc] initWithFrame:CGRectZero];
        track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.32];
        track.layer.cornerRadius = 1.5;
        track.layer.masksToBounds = YES;
        [self.progressContainer addSubview:track];

        UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
        fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
        [track addSubview:fill];
        [self.progressFills addObject:fill];
    }
}

- (void)layoutProgressSegments {
    NSUInteger count = self.progressContainer.subviews.count;
    if (count == 0) return;
    CGFloat gap = 3.0;
    CGFloat totalGap = gap * (count - 1);
    CGFloat segmentWidth = floor((self.progressContainer.bounds.size.width - totalGap) / count);
    CGFloat x = 0.0;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *track = self.progressContainer.subviews[index];
        track.frame = CGRectMake(x, 0, segmentWidth, 3.0);
        UIView *fill = self.progressFills[index];
        [fill.layer removeAllAnimations];
        CGFloat ratio = (NSInteger)index < self.currentIndex ? 1.0 : 0.0;
        if ((NSInteger)index == self.currentIndex) ratio = 0.0;
        fill.frame = CGRectMake(0, 0, segmentWidth * ratio, 3.0);
        x += segmentWidth + gap;
    }
}

- (void)updateProgressSegments {
    NSUInteger count = self.progressFills.count;
    for (NSUInteger index = 0; index < count; index++) {
        UIView *track = self.progressContainer.subviews[index];
        UIView *fill = self.progressFills[index];
        [fill.layer removeAllAnimations];
        CGFloat ratio = (NSInteger)index < self.currentIndex ? 1.0 : 0.0;
        fill.frame = CGRectMake(0, 0, track.bounds.size.width * ratio, track.bounds.size.height);
    }
}

- (void)animateCurrentProgressForDuration:(NSTimeInterval)duration {
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)self.progressFills.count) return;
    UIView *track = self.progressContainer.subviews[self.currentIndex];
    UIView *fill = self.progressFills[self.currentIndex];
    [fill.layer removeAllAnimations];
    fill.frame = CGRectMake(0, 0, 0, track.bounds.size.height);
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveLinear animations:^{
        fill.frame = CGRectMake(0, 0, track.bounds.size.width, track.bounds.size.height);
    } completion:nil];
}

- (void)applyCubeTransitionForward:(BOOL)forward {
    if (!self.hasDisplayedMedia) return;
    CATransition *transition = [CATransition animation];
    transition.type = @"cube";
    transition.subtype = forward ? kCATransitionFromRight : kCATransitionFromLeft;
    transition.duration = 0.42;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.mediaView.layer addAnimation:transition forKey:@"pc-story-cube"];
}

- (void)displayImage:(UIImage *)image animatedForward:(BOOL)forward {
    [self.timer invalidate];
    self.timer = nil;
    [self applyCubeTransitionForward:forward];
    [self.mediaView configureWithImage:image];
    self.hasDisplayedMedia = YES;
}

- (void)displayPlayer:(AVPlayer *)player animatedForward:(BOOL)forward {
    [self.timer invalidate];
    self.timer = nil;
    [self applyCubeTransitionForward:forward];
    [self.mediaView configureWithPlayer:player];
    self.hasDisplayedMedia = YES;
}

- (void)showFeedAtIndex:(NSInteger)index forward:(BOOL)forward {
    if (self.feeds.count == 0) return;
    if (index < 0) {
        [self loadParkAtIndex:self.parkIndex - 1 startStoryIndex:NSIntegerMax forward:NO];
        return;
    }
    if (index >= (NSInteger)self.feeds.count) {
        [self loadParkAtIndex:self.parkIndex + 1 startStoryIndex:0 forward:YES];
        return;
    }
    self.currentIndex = index;
    PCCameraFeed *feed = self.feeds[index];
    self.feedLabel.text = feed.title.length ? feed.title : @"Live park story";
    [self updateProgressSegments];
    [self.timer invalidate];
    self.timer = nil;

    if (feed.streamURL.length) {
        NSURL *url = [NSURL URLWithString:feed.streamURL];
        if (!url) {
            [self nextStory];
            return;
        }
        AVPlayer *player = [AVPlayer playerWithURL:url];
        player.muted = YES;
        [self displayPlayer:player animatedForward:forward];
        [player play];
        [self scheduleAdvanceForFeed:feed];
        return;
    }

    self.feedLabel.text = feed.title.length ? feed.title : @"Loading live still...";
    __weak typeof(self) weakSelf = self;
    NSInteger capturedParkIndex = self.parkIndex;
    [[PCImageLoader sharedLoader] loadFreshImageAtURL:feed.imageURL completion:^(UIImage *image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.currentIndex != index || strongSelf.parkIndex != capturedParkIndex || index >= (NSInteger)strongSelf.feeds.count || strongSelf.feeds[index] != feed) return;
        if (!image) {
            [strongSelf nextStory];
            return;
        }
        [strongSelf displayImage:image animatedForward:forward];
        [strongSelf scheduleAdvanceForFeed:feed];
    }];
}

@end

@interface PCSocialStoryCell : UICollectionViewCell

@property (nonatomic, strong) UIView *ringView;
@property (nonatomic, strong) UIImageView *avatarImageView;
@property (nonatomic, strong) UILabel *avatarLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *liveLabel;
@property (nonatomic, copy) NSString *representedCode;
- (void)configureWithPark:(PCCameraPark *)park;

@end

@implementation PCSocialStoryCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.ringView = [[UIView alloc] initWithFrame:CGRectZero];
        self.ringView.backgroundColor = [UIColor colorWithRed:0.94 green:0.20 blue:0.43 alpha:1.0];
        [self.contentView addSubview:self.ringView];

        self.avatarImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.avatarImageView.backgroundColor = PCSocialWhite();
        self.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarImageView.clipsToBounds = YES;
        self.avatarImageView.layer.masksToBounds = YES;
        [self.contentView addSubview:self.avatarImageView];

        self.avatarLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.avatarLabel.textAlignment = NSTextAlignmentCenter;
        self.avatarLabel.textColor = PCSocialText();
        self.avatarLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.88];
        self.avatarLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBlack];
        self.avatarLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.avatarLabel];

        self.liveLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.liveLabel.text = @"LIVE";
        self.liveLabel.textColor = [UIColor whiteColor];
        self.liveLabel.textAlignment = NSTextAlignmentCenter;
        self.liveLabel.font = [UIFont systemFontOfSize:8.0 weight:UIFontWeightBlack];
        self.liveLabel.backgroundColor = [UIColor colorWithRed:0.95 green:0.08 blue:0.22 alpha:0.96];
        self.liveLabel.layer.cornerRadius = 3.0;
        self.liveLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.liveLabel];

        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.titleLabel.textColor = PCSocialText();
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:self.titleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat centerX = self.contentView.bounds.size.width / 2.0;
    self.ringView.frame = CGRectMake(centerX - 31.0, 4.0, 62.0, 62.0);
    self.ringView.layer.cornerRadius = 31.0;
    self.avatarImageView.frame = CGRectMake(centerX - 27.0, 8.0, 54.0, 54.0);
    self.avatarImageView.layer.cornerRadius = 27.0;
    self.avatarLabel.frame = CGRectMake(centerX - 27.0, 8.0, 54.0, 54.0);
    self.avatarLabel.layer.cornerRadius = 27.0;
    self.liveLabel.frame = CGRectMake(centerX + 4.0, 50.0, 36.0, 16.0);
    self.titleLabel.frame = CGRectMake(1.0, 70.0, self.contentView.bounds.size.width - 2.0, 18.0);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedCode = nil;
    self.avatarImageView.image = nil;
    self.avatarLabel.hidden = NO;
}

- (void)configureWithPark:(PCCameraPark *)park {
    self.representedCode = park.code;
    self.avatarLabel.text = PCInitialsForPark(park);
    self.titleLabel.text = park.name;
    self.liveLabel.hidden = !park.hasLiveVideo;
    [[PCImageLoader sharedLoader] loadParkImageForCode:park.code imageURL:park.heroImageURL completion:^(UIImage *image) {
        if (image && [self.representedCode isEqualToString:park.code]) {
            self.avatarImageView.image = image;
            self.avatarLabel.hidden = YES;
        }
    }];
}

@end

@interface PCSocialPostCell : UITableViewCell

@property (nonatomic, strong) UILabel *avatarLabel;
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UIImageView *postImageView;
@property (nonatomic, strong) UILabel *storyBadgeLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, copy) NSString *representedImageURL;
- (void)configureWithPost:(PCSocialPost *)post;

@end

@implementation PCSocialPostCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = PCSocialWhite();
        self.contentView.backgroundColor = PCSocialWhite();

        self.avatarLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.avatarLabel.textAlignment = NSTextAlignmentCenter;
        self.avatarLabel.textColor = PCSocialText();
        self.avatarLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
        self.avatarLabel.layer.borderColor = [UIColor colorWithWhite:0.1 alpha:1.0].CGColor;
        self.avatarLabel.layer.borderWidth = 1.0;
        self.avatarLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.avatarLabel];

        self.accountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.accountLabel.textColor = PCSocialText();
        self.accountLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBlack];
        [self.contentView addSubview:self.accountLabel];

        self.sourceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.sourceLabel.textColor = [UIColor colorWithWhite:0.36 alpha:1.0];
        self.sourceLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        [self.contentView addSubview:self.sourceLabel];

        self.postImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.postImageView.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        self.postImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.postImageView.clipsToBounds = YES;
        [self.contentView addSubview:self.postImageView];

        self.storyBadgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.storyBadgeLabel.textColor = [UIColor whiteColor];
        self.storyBadgeLabel.textAlignment = NSTextAlignmentCenter;
        self.storyBadgeLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBlack];
        self.storyBadgeLabel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.78];
        self.storyBadgeLabel.layer.cornerRadius = 4.0;
        self.storyBadgeLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.storyBadgeLabel];

        self.captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.captionLabel.textColor = PCSocialText();
        self.captionLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        self.captionLabel.numberOfLines = 2;
        [self.contentView addSubview:self.captionLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedImageURL = nil;
    self.postImageView.image = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    self.avatarLabel.frame = CGRectMake(12.0, 10.0, 34.0, 34.0);
    self.avatarLabel.layer.cornerRadius = 17.0;
    self.accountLabel.frame = CGRectMake(54.0, 8.0, width - 70.0, 20.0);
    self.sourceLabel.frame = CGRectMake(54.0, 28.0, width - 70.0, 16.0);
    CGFloat imageY = 52.0;
    CGFloat imageHeight = width * 0.78;
    self.postImageView.frame = CGRectMake(0.0, imageY, width, imageHeight);
    self.storyBadgeLabel.frame = CGRectMake(12.0, imageY + 12.0, 88.0, 22.0);
    self.captionLabel.frame = CGRectMake(12.0, imageY + imageHeight + 12.0, width - 24.0, 40.0);
}

- (UIImage *)placeholderImageWithText:(NSString *)text {
    CGSize size = CGSizeMake(320.0, 250.0);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0);
    [[UIColor colorWithWhite:0.94 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:42.0 weight:UIFontWeightBlack],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.25 alpha:1.0]
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    [text drawAtPoint:CGPointMake((size.width - textSize.width) / 2.0, (size.height - textSize.height) / 2.0) withAttributes:attributes];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)configureWithPost:(PCSocialPost *)post {
    PCCameraPark *park = post.park;
    PCParkPhoto *photo = post.photo;
    self.avatarLabel.text = PCInitialsForPark(park);
    self.accountLabel.text = PCHandleForPark(park);
    self.sourceLabel.text = park.region.length ? park.region : @"National Park Service";
    self.storyBadgeLabel.text = park.hasLiveVideo ? @"LIVE STORY" : @"STORIES";
    self.storyBadgeLabel.hidden = PCAvailableFeedsForPark(park).count == 0;
    self.captionLabel.text = [NSString stringWithFormat:@"%@  %@", park.name ?: @"Park", photo.caption.length ? photo.caption : park.detail ?: @""];
    self.representedImageURL = photo.url;
    self.postImageView.image = [self placeholderImageWithText:PCInitialsForPark(park)];
    if (photo.url.length) {
        [[PCImageLoader sharedLoader] loadImageAtURL:photo.url completion:^(UIImage *image) {
            if (image && [self.representedImageURL isEqualToString:photo.url]) {
                self.postImageView.image = image;
            }
        }];
    }
}

@end

@interface PCParkProfileViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) PCCameraPark *park;
@property (nonatomic, copy) NSArray<PCSocialPost *> *posts;
@property (nonatomic, copy) NSArray<PCCameraFeed *> *feeds;
@property (nonatomic, strong) UITableView *tableView;
- (instancetype)initWithPark:(PCCameraPark *)park;

@end

@implementation PCParkProfileViewController

- (instancetype)initWithPark:(PCCameraPark *)park {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.park = park;
        self.feeds = PCAvailableFeedsForPark(park);
        NSMutableArray *posts = [NSMutableArray array];
        for (PCParkPhoto *photo in park.postImages) {
            [posts addObject:[PCSocialPost postWithPark:park photo:photo]];
        }
        self.posts = posts;
        self.title = park.name;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PCSocialWhite();
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = PCSocialWhite();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = [self profileHeaderView];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.barTintColor = PCSocialWhite();
    self.navigationController.navigationBar.tintColor = PCSocialText();
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: PCSocialText(),
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };
}

- (UIView *)profileHeaderView {
    CGFloat width = [UIScreen mainScreen].bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 214.0)];
    header.backgroundColor = PCSocialWhite();

    UIImageView *hero = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, width, 112.0)];
    hero.contentMode = UIViewContentModeScaleAspectFill;
    hero.clipsToBounds = YES;
    hero.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    [header addSubview:hero];
    [[PCImageLoader sharedLoader] loadImageAtURL:self.park.heroImageURL completion:^(UIImage *image) {
        if (image) hero.image = image;
    }];

    UILabel *avatar = [[UILabel alloc] initWithFrame:CGRectMake(16.0, 76.0, 72.0, 72.0)];
    avatar.text = PCInitialsForPark(self.park);
    avatar.textAlignment = NSTextAlignmentCenter;
    avatar.textColor = PCSocialText();
    avatar.backgroundColor = PCSocialWhite();
    avatar.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBlack];
    avatar.layer.cornerRadius = 36.0;
    avatar.layer.borderColor = PCSocialWhite().CGColor;
    avatar.layer.borderWidth = 4.0;
    avatar.layer.masksToBounds = YES;
    [header addSubview:avatar];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(100.0, 118.0, width - 116.0, 24.0)];
    name.text = self.park.name;
    name.textColor = PCSocialText();
    name.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBlack];
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.72;
    [header addSubview:name];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectMake(100.0, 142.0, width - 116.0, 18.0)];
    meta.text = [NSString stringWithFormat:@"%@  |  %ld posts  |  %ld stories", self.park.region ?: @"NPS", (long)self.posts.count, (long)self.feeds.count];
    meta.textColor = [UIColor colorWithWhite:0.38 alpha:1.0];
    meta.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    meta.adjustsFontSizeToFitWidth = YES;
    meta.minimumScaleFactor = 0.72;
    [header addSubview:meta];

    UIButton *storyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    storyButton.frame = CGRectMake(16.0, 166.0, width - 32.0, 36.0);
    storyButton.backgroundColor = self.feeds.count ? PCSocialText() : [UIColor colorWithWhite:0.85 alpha:1.0];
    storyButton.tintColor = self.feeds.count ? [UIColor whiteColor] : [UIColor colorWithWhite:0.45 alpha:1.0];
    storyButton.layer.cornerRadius = 7.0;
    storyButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBlack];
    [storyButton setTitle:self.feeds.count ? @"Watch Stories" : @"No live stories right now" forState:UIControlStateNormal];
    [storyButton addTarget:self action:@selector(watchStoriesTapped) forControlEvents:UIControlEventTouchUpInside];
    storyButton.enabled = self.feeds.count > 0;
    [header addSubview:storyButton];

    return header;
}

- (void)watchStoriesTapped {
    if (self.feeds.count == 0) return;
    PCSocialStoryViewController *controller = [[PCSocialStoryViewController alloc] initWithPark:self.park feeds:self.feeds];
    [self presentViewController:controller animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.posts.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.bounds.size.width * 0.78 + 106.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ProfilePostCell";
    PCSocialPostCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[PCSocialPostCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    [cell configureWithPost:self.posts[indexPath.row]];
    return cell;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [[PCImageLoader sharedLoader] clearMemoryCache];
}

@end

@interface PCSocialFeedViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSArray<PCCameraPark *> *storyParks;
@property (nonatomic, copy) NSArray<PCSocialPost *> *posts;
@property (nonatomic, strong) UICollectionView *storiesView;
@property (nonatomic, strong) UITableView *tableView;
- (instancetype)initWithParks:(NSArray<PCCameraPark *> *)parks;

@end

@implementation PCSocialFeedViewController

- (instancetype)initWithParks:(NSArray<PCCameraPark *> *)parks {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        NSMutableArray *storyParks = [NSMutableArray array];
        NSMutableArray *posts = [NSMutableArray array];
        for (PCCameraPark *park in parks) {
            if (PCAvailableFeedsForPark(park).count) [storyParks addObject:park];
            NSUInteger postLimit = MIN((NSUInteger)2, park.postImages.count);
            for (NSUInteger index = 0; index < postLimit; index++) {
                [posts addObject:[PCSocialPost postWithPark:park photo:park.postImages[index]]];
            }
        }
        self.storyParks = storyParks;
        self.posts = posts;
        self.title = @"RangerLens";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PCSocialWhite();
    [self buildInterface];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.barTintColor = PCSocialWhite();
    self.navigationController.navigationBar.tintColor = PCSocialText();
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: PCSocialText(),
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBar.barTintColor = [UIColor colorWithRed:0.04 green:0.10 blue:0.13 alpha:1.0];
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0];
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };
}

- (void)buildInterface {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize = CGSizeMake(78.0, 92.0);
    layout.minimumLineSpacing = 6.0;
    layout.sectionInset = UIEdgeInsetsMake(0, 8, 0, 8);

    self.storiesView = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 98.0) collectionViewLayout:layout];
    self.storiesView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.storiesView.backgroundColor = PCSocialWhite();
    self.storiesView.showsHorizontalScrollIndicator = NO;
    self.storiesView.dataSource = self;
    self.storiesView.delegate = self;
    [self.storiesView registerClass:[PCSocialStoryCell class] forCellWithReuseIdentifier:@"StoryCell"];
    [self.view addSubview:self.storiesView];

    UIView *rule = [[UIView alloc] initWithFrame:CGRectMake(0, 97.0, self.view.bounds.size.width, 1.0)];
    rule.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    rule.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    [self.view addSubview:rule];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 98.0, self.view.bounds.size.width, self.view.bounds.size.height - 98.0) style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = PCSocialWhite();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.tableView];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.storyParks.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    PCSocialStoryCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"StoryCell" forIndexPath:indexPath];
    [cell configureWithPark:self.storyParks[indexPath.item]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    PCSocialStoryViewController *controller = [[PCSocialStoryViewController alloc] initWithParks:self.storyParks startIndex:indexPath.item];
    [self presentViewController:controller animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.posts.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.bounds.size.width * 0.78 + 106.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"SocialPostCell";
    PCSocialPostCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[PCSocialPostCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    [cell configureWithPost:self.posts[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PCSocialPost *post = self.posts[indexPath.row];
    PCParkProfileViewController *controller = [[PCParkProfileViewController alloc] initWithPark:post.park];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [[PCImageLoader sharedLoader] clearMemoryCache];
}

@end

@interface PCSlideshowViewController : UIViewController

@property (nonatomic, strong) NSArray<PCCameraPark *> *parks;
@property (nonatomic, strong) NSMutableArray<PCSlideshowItem *> *items;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView *overlayView;
@property (nonatomic, strong) CAGradientLayer *overlayGradient;
@property (nonatomic, strong) UILabel *parkLabel;
@property (nonatomic, strong) UILabel *regionLabel;
@property (nonatomic, strong) UILabel *feedLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSSet<NSString *> *parkCodes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *imageCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *imageDates;
@property (nonatomic, strong) NSMutableArray<NSString *> *imageCacheOrder;
@property (nonatomic, strong) NSMutableSet<NSString *> *loadingImageURLs;
@property (nonatomic) NSInteger currentIndex;
@property (nonatomic) BOOL hasStarted;
@property (nonatomic) BOOL isRefreshingManifest;

- (instancetype)initWithParks:(NSArray<PCCameraPark *> *)parks;

@end

@implementation PCSlideshowViewController

- (instancetype)initWithParks:(NSArray<PCCameraPark *> *)parks {
    self = [super init];
    if (self) {
        NSMutableArray *eligible = [NSMutableArray array];
        for (PCCameraPark *park in parks) {
            if (park.feedCount > 0) [eligible addObject:park];
        }
        self.parks = eligible;
        self.items = [NSMutableArray array];
        NSMutableSet *codes = [NSMutableSet set];
        for (PCCameraPark *park in eligible) {
            if (park.code.length) [codes addObject:park.code];
        }
        self.parkCodes = codes;
        self.imageCache = [NSMutableDictionary dictionary];
        self.imageDates = [NSMutableDictionary dictionary];
        self.imageCacheOrder = [NSMutableArray array];
        self.loadingImageURLs = [NSMutableSet set];
        self.currentIndex = NSNotFound;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.imageView = [[UIImageView alloc] init];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
    self.imageView.clipsToBounds = YES;
    self.imageView.backgroundColor = [UIColor colorWithRed:0.02 green:0.05 blue:0.05 alpha:1.0];
    [self.view addSubview:self.imageView];

    self.overlayView = [[UIView alloc] init];
    self.overlayView.translatesAutoresizingMaskIntoConstraints = NO;
    self.overlayView.userInteractionEnabled = NO;
    self.overlayGradient = [CAGradientLayer layer];
    self.overlayGradient.colors = @[
        (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.55].CGColor,
        (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.90].CGColor
    ];
    self.overlayGradient.locations = @[@0.0, @0.48, @1.0];
    [self.overlayView.layer addSublayer:self.overlayGradient];
    [self.view addSubview:self.overlayView];

    UIButton *doneButton = [self chromeButtonWithTitle:@"Done"];
    doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:doneButton];

    UIButton *nextButton = [self chromeButtonWithTitle:@"Next"];
    nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nextButton];

    self.regionLabel = [[UILabel alloc] init];
    self.regionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.regionLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
    self.regionLabel.textColor = [UIColor colorWithRed:1.0 green:0.83 blue:0.43 alpha:1.0];
    self.regionLabel.numberOfLines = 1;
    [self.view addSubview:self.regionLabel];

    self.parkLabel = [[UILabel alloc] init];
    self.parkLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.parkLabel.font = [UIFont systemFontOfSize:36.0 weight:UIFontWeightBlack];
    self.parkLabel.textColor = [UIColor whiteColor];
    self.parkLabel.numberOfLines = 2;
    self.parkLabel.adjustsFontSizeToFitWidth = YES;
    self.parkLabel.minimumScaleFactor = 0.72;
    [self.view addSubview:self.parkLabel];

    self.feedLabel = [[UILabel alloc] init];
    self.feedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.feedLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.feedLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    self.feedLabel.numberOfLines = 2;
    [self.view addSubview:self.feedLabel];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    self.statusLabel.text = @"Finding working still webcams...";
    [self.view addSubview:self.statusLabel];

    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
    self.progressLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    self.progressLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.progressLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.imageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.imageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.overlayView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.overlayView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.overlayView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.overlayView.heightAnchor constraintEqualToConstant:210.0],

        [doneButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [doneButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [doneButton.widthAnchor constraintEqualToConstant:70.0],
        [doneButton.heightAnchor constraintEqualToConstant:34.0],

        [nextButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
        [nextButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [nextButton.widthAnchor constraintEqualToConstant:70.0],
        [nextButton.heightAnchor constraintEqualToConstant:34.0],

        [self.regionLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24.0],
        [self.regionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.progressLabel.leadingAnchor constant:-16.0],
        [self.regionLabel.bottomAnchor constraintEqualToAnchor:self.parkLabel.topAnchor constant:-4.0],

        [self.parkLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22.0],
        [self.parkLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-92.0],
        [self.parkLabel.bottomAnchor constraintEqualToAnchor:self.feedLabel.topAnchor constant:-6.0],

        [self.feedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24.0],
        [self.feedLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24.0],
        [self.feedLabel.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-8.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.progressLabel.leadingAnchor constant:-12.0],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18.0],

        [self.progressLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24.0],
        [self.progressLabel.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.progressLabel.widthAnchor constraintEqualToConstant:70.0]
    ]];

    BOOL hasCachedItems = [self loadCachedManifest];
    if (![self hasFreshManifest]) {
        [self refreshManifest];
    } else if (!hasCachedItems) {
        self.statusLabel.text = @"No cached webcam images found.";
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.overlayGradient.frame = self.overlayView.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self.timer invalidate];
    self.timer = nil;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self.imageCache removeAllObjects];
    [self.imageDates removeAllObjects];
    [self.imageCacheOrder removeAllObjects];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (UIButton *)chromeButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.36];
    button.layer.cornerRadius = 17.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    return button;
}

- (void)doneTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)nextTapped {
    [self showNextItem];
}

- (void)startTimerIfNeeded {
    if (self.timer) return;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(showNextItem) userInfo:nil repeats:YES];
}

- (BOOL)loadCachedManifest {
    NSDictionary *manifest = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PCSlideshowManifestCacheKey];
    NSArray *rawItems = manifest[@"items"];
    if (![rawItems isKindOfClass:[NSArray class]]) return NO;

    NSMutableArray<PCSlideshowItem *> *cachedItems = [NSMutableArray array];
    for (NSDictionary *rawItem in rawItems) {
        PCSlideshowItem *item = [PCSlideshowItem itemWithDictionary:rawItem];
        if (item && (item.parkCode.length == 0 || [self.parkCodes containsObject:item.parkCode])) {
            [cachedItems addObject:item];
        }
    }

    if (cachedItems.count == 0) return NO;
    [self.items addObjectsFromArray:cachedItems];
    self.hasStarted = YES;
    [self showItemAtIndex:0];
    [self startTimerIfNeeded];
    return YES;
}

- (BOOL)hasFreshManifest {
    NSDictionary *manifest = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PCSlideshowManifestCacheKey];
    NSNumber *timestamp = manifest[@"timestamp"];
    if (![timestamp isKindOfClass:[NSNumber class]]) return NO;
    return ([[NSDate date] timeIntervalSince1970] - [timestamp doubleValue]) < PCSlideshowManifestMaxAge;
}

- (void)saveManifestWithItems:(NSArray<PCSlideshowItem *> *)items {
    if (items.count == 0) return;
    NSMutableArray *rawItems = [NSMutableArray arrayWithCapacity:items.count];
    for (PCSlideshowItem *item in items) {
        [rawItems addObject:[item dictionaryRepresentation]];
    }
    NSDictionary *manifest = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"items": rawItems
    };
    [[NSUserDefaults standardUserDefaults] setObject:manifest forKey:PCSlideshowManifestCacheKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)refreshManifest {
    if (self.isRefreshingManifest) return;
    self.isRefreshingManifest = YES;
    [self loadParkAtIndex:0 collectingItems:[NSMutableArray array]];
}

- (void)finishManifestRefreshWithItems:(NSArray<PCSlideshowItem *> *)freshItems {
    self.isRefreshingManifest = NO;
    if (freshItems.count == 0) {
        if (self.items.count == 0) self.statusLabel.text = @"No working still webcams found.";
        return;
    }

    [self saveManifestWithItems:freshItems];
    BOOL shouldStart = self.items.count == 0;
    [self.items removeAllObjects];
    [self.items addObjectsFromArray:freshItems];
    if (shouldStart) {
        self.hasStarted = YES;
        [self showItemAtIndex:0];
        [self startTimerIfNeeded];
    } else {
        if (self.currentIndex >= self.items.count) self.currentIndex = 0;
        self.progressLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)self.currentIndex + 1, (long)self.items.count];
    }
}

- (void)loadParkAtIndex:(NSUInteger)index collectingItems:(NSMutableArray<PCSlideshowItem *> *)collectedItems {
    if (index >= self.parks.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishManifestRefreshWithItems:collectedItems];
        });
        return;
    }

    PCCameraPark *park = self.parks[index];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.items.count == 0) {
            self.statusLabel.text = [NSString stringWithFormat:@"Checking %@...", park.name];
        }
    });

    if (park.manifestFeeds.count) {
        for (PCCameraFeed *feed in park.manifestFeeds) {
            if (feed.available && feed.imageURL.length && feed.streamURL.length == 0) {
                [collectedItems addObject:[PCSlideshowItem itemWithPark:park feed:feed]];
            }
        }
        [self loadParkAtIndex:index + 1 collectingItems:collectedItems];
        return;
    }

    NSURL *url = [NSURL URLWithString:park.webcamURL];
    if (!url) {
        [self loadParkAtIndex:index + 1 collectingItems:collectedItems];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        PCFeedListViewController *parser = [[PCFeedListViewController alloc] initWithPark:park];
        NSArray<PCCameraFeed *> *feeds = [parser parseFeedsFromHTML:html baseURL:park.webcamURL];
        NSMutableArray<PCCameraFeed *> *stillFeeds = [NSMutableArray array];
        for (PCCameraFeed *feed in feeds) {
            if (feed.imageURL.length && feed.streamURL.length == 0) {
                [stillFeeds addObject:feed];
            }
        }

        [parser validateFeeds:stillFeeds completion:^(NSArray<PCCameraFeed *> *validFeeds) {
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (!innerSelf) return;
            for (PCCameraFeed *feed in validFeeds) {
                [collectedItems addObject:[PCSlideshowItem itemWithPark:park feed:feed]];
            }
            [innerSelf loadParkAtIndex:index + 1 collectingItems:collectedItems];
        }];
    }] resume];
}

- (NSString *)cacheBustedURL:(NSString *)url {
    return PCURLByAddingRefreshToken(url, @"rangerlens");
}

- (BOOL)hasFreshCachedImageForURL:(NSString *)url {
    if (url.length == 0) return NO;
    NSDate *date = self.imageDates[url];
    if (!self.imageCache[url] || !date) return NO;
    return [[NSDate date] timeIntervalSinceDate:date] < PCSlideshowImageMaxAge;
}

- (NSString *)statusTextForImageDate:(NSDate *)date refreshing:(BOOL)refreshing {
    if (refreshing) return @"Refreshing image...";
    if (!date) return @"Loading latest image...";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:@"Updated %@", [formatter stringFromDate:date]];
}

- (UIImage *)displaySizedImage:(UIImage *)image {
    if (!image) return nil;
    CGSize targetSize = self.view.bounds.size;
    if (targetSize.width < 1.0 || targetSize.height < 1.0) targetSize = [UIScreen mainScreen].bounds.size;
    CGFloat scale = MAX(targetSize.width / image.size.width, targetSize.height / image.size.height);
    CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
    CGRect drawRect = CGRectMake((targetSize.width - drawSize.width) * 0.5,
                                 (targetSize.height - drawSize.height) * 0.5,
                                 drawSize.width,
                                 drawSize.height);
    UIGraphicsBeginImageContextWithOptions(targetSize, YES, 0.0);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, targetSize.width, targetSize.height));
    [image drawInRect:drawRect];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaled ?: image;
}

- (void)storeImage:(UIImage *)image forURL:(NSString *)url {
    if (!image || url.length == 0) return;
    self.imageCache[url] = image;
    self.imageDates[url] = [NSDate date];
    [self.imageCacheOrder removeObject:url];
    [self.imageCacheOrder addObject:url];
    while (self.imageCacheOrder.count > PCSlideshowImageCacheLimit) {
        NSString *oldestURL = self.imageCacheOrder.firstObject;
        if (!oldestURL) break;
        [self.imageCache removeObjectForKey:oldestURL];
        [self.imageDates removeObjectForKey:oldestURL];
        [self.imageCacheOrder removeObjectAtIndex:0];
    }
}

- (void)displayImage:(UIImage *)image date:(NSDate *)date refreshing:(BOOL)refreshing animated:(BOOL)animated {
    void (^changes)(void) = ^{
        self.imageView.image = image;
    };
    if (animated && self.imageView.image) {
        [UIView transitionWithView:self.imageView
                          duration:0.45
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:changes
                        completion:nil];
    } else {
        changes();
    }
    self.statusLabel.text = [self statusTextForImageDate:date refreshing:refreshing];
}

- (void)fetchImageForItem:(PCSlideshowItem *)item displayIndex:(NSInteger)displayIndex prefetch:(BOOL)prefetch {
    if (item.imageURL.length == 0 || [self.loadingImageURLs containsObject:item.imageURL]) return;
    [self.loadingImageURLs addObject:item.imageURL];

    NSString *urlString = [self cacheBustedURL:item.imageURL];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self.loadingImageURLs removeObject:item.imageURL];
        if (!prefetch) self.statusLabel.text = @"Image unavailable right now.";
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:prefetch ? 10.0 : 14.0];
    [request setValue:@"RangerLens" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = PCImageFromDataScaled(data, 1500.0);
        BOOL freshEnough = image && PCResponseIsFreshEnough(response, PCStillFeedMaxAge);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingImageURLs removeObject:item.imageURL];
            UIImage *scaled = [strongSelf displaySizedImage:image];
            if (scaled && freshEnough) {
                [strongSelf storeImage:scaled forURL:item.imageURL];
                if (!prefetch && strongSelf.currentIndex == displayIndex) {
                    [strongSelf displayImage:scaled date:strongSelf.imageDates[item.imageURL] refreshing:NO animated:YES];
                    [strongSelf prefetchUpcomingItemsFromIndex:displayIndex];
                }
            } else if (image && !freshEnough && !prefetch && strongSelf.currentIndex == displayIndex) {
                [strongSelf skipStaleItemAtIndex:displayIndex];
            } else if (!prefetch && strongSelf.currentIndex == displayIndex && !strongSelf.imageCache[item.imageURL]) {
                strongSelf.statusLabel.text = @"Image unavailable right now.";
            }
        });
    }] resume];
}

- (void)prefetchUpcomingItemsFromIndex:(NSInteger)index {
    if (self.items.count < 2) return;
    NSUInteger prefetchCount = MIN((NSUInteger)3, self.items.count - 1);
    for (NSUInteger offset = 1; offset <= prefetchCount; offset++) {
        NSInteger nextIndex = (index + offset) % self.items.count;
        PCSlideshowItem *item = self.items[nextIndex];
        if (![self hasFreshCachedImageForURL:item.imageURL]) {
            [self fetchImageForItem:item displayIndex:nextIndex prefetch:YES];
        }
    }
}

- (void)skipStaleItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.items.count || self.currentIndex != index) return;
    if (self.items.count <= 1) {
        self.imageView.image = nil;
        self.statusLabel.text = @"This camera image is stale right now.";
        return;
    }
    [self.items removeObjectAtIndex:index];
    self.currentIndex = index == 0 ? self.items.count - 1 : index - 1;
    self.statusLabel.text = @"Skipping stale camera image...";
    [self showNextItem];
}

- (void)showNextItem {
    if (self.items.count == 0) return;
    NSInteger nextIndex = self.currentIndex == NSNotFound ? 0 : (self.currentIndex + 1) % self.items.count;
    [self showItemAtIndex:nextIndex];
}

- (void)showItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.items.count) return;
    self.currentIndex = index;
    PCSlideshowItem *item = self.items[index];
    self.regionLabel.text = [item.region uppercaseString];
    self.parkLabel.text = item.parkName;
    self.feedLabel.text = item.feedTitle.length ? item.feedTitle : @"Webcam";
    self.progressLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)index + 1, (long)self.items.count];

    UIImage *cachedImage = self.imageCache[item.imageURL];
    BOOL fresh = [self hasFreshCachedImageForURL:item.imageURL];
    if (cachedImage) {
        [self displayImage:cachedImage date:self.imageDates[item.imageURL] refreshing:!fresh animated:YES];
        if (!fresh) [self fetchImageForItem:item displayIndex:index prefetch:NO];
        [self prefetchUpcomingItemsFromIndex:index];
        return;
    }

    self.statusLabel.text = @"Loading latest image...";
    [self fetchImageForItem:item displayIndex:index prefetch:NO];
}

@end

@interface ParkCamsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, strong) NSArray<PCCameraPark *> *parks;
@property (nonatomic, strong) NSArray<PCCameraPark *> *filteredParks;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIButton *filterButton;
@property (nonatomic, strong) UIButton *slideshowButton;
@property (nonatomic, strong) UIButton *socialButton;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) CAGradientLayer *backgroundGradient;
@property (nonatomic, copy) NSString *selectedCategory;

@end

@implementation ParkCamsViewController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.08 alpha:1.0];
    self.parks = [self buildCatalog];
    self.filteredParks = self.parks;
    self.selectedCategory = @"All";

    self.backgroundGradient = [CAGradientLayer layer];
    self.backgroundGradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.05 green:0.17 blue:0.17 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.03 green:0.07 blue:0.08 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.02 green:0.04 blue:0.05 alpha:1.0].CGColor
    ];
    [self.view.layer insertSublayer:self.backgroundGradient atIndex:0];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 148.0;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[PCCameraCell class] forCellReuseIdentifier:@"CameraCell"];
    [self.view addSubview:self.tableView];
    self.tableView.tableHeaderView = [self makeHeaderView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [self updateCountLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.backgroundGradient.frame = self.view.bounds;
    UIView *header = self.tableView.tableHeaderView;
    CGFloat tableWidth = self.tableView.bounds.size.width;
    if (header && fabs(header.frame.size.width - tableWidth) > 0.5) {
        CGRect frame = header.frame;
        frame.size.width = tableWidth;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [[PCImageLoader sharedLoader] clearMemoryCache];
}

- (UIView *)makeHeaderView {
    CGFloat width = self.view.bounds.size.width > 0.0 ? self.view.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 138.0)];
    header.backgroundColor = [UIColor clearColor];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 14.0, width - 216.0, 42.0)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBlack];
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.70;
    title.textColor = [UIColor whiteColor];
    title.text = @"RangerLens";
    [header addSubview:title];

    self.socialButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.socialButton.frame = CGRectMake(width - 196.0, 18.0, 74.0, 34.0);
    self.socialButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.socialButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBlack];
    self.socialButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.socialButton.tintColor = [UIColor colorWithWhite:0.98 alpha:1.0];
    self.socialButton.layer.cornerRadius = 8.0;
    self.socialButton.layer.borderWidth = 1.0;
    self.socialButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [self.socialButton setTitle:@"Social" forState:UIControlStateNormal];
    [self.socialButton addTarget:self action:@selector(startSocialFeed) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.socialButton];

    self.slideshowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.slideshowButton.frame = CGRectMake(width - 114.0, 18.0, 94.0, 34.0);
    self.slideshowButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.slideshowButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBlack];
    self.slideshowButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:0.16];
    self.slideshowButton.tintColor = [UIColor colorWithRed:1.0 green:0.86 blue:0.50 alpha:1.0];
    self.slideshowButton.layer.cornerRadius = 8.0;
    self.slideshowButton.layer.borderWidth = 1.0;
    self.slideshowButton.layer.borderColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:0.45].CGColor;
    [self.slideshowButton setTitle:@"Slideshow" forState:UIControlStateNormal];
    [self.slideshowButton addTarget:self action:@selector(startSlideshow) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.slideshowButton];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(8.0, 68.0, width - 88.0, 44.0)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search park, state, or view";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.tintColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0];
    [header addSubview:self.searchBar];

    self.filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.filterButton.frame = CGRectMake(width - 72.0, 72.0, 60.0, 36.0);
    self.filterButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.filterButton.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBlack];
    self.filterButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.filterButton.tintColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0];
    self.filterButton.layer.cornerRadius = 8.0;
    self.filterButton.layer.borderColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:0.42].CGColor;
    self.filterButton.layer.borderWidth = 1.0;
    [self.filterButton addTarget:self action:@selector(filterTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.filterButton];

    self.countLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 114.0, width - 40.0, 18.0)];
    self.countLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.countLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBlack];
    self.countLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    self.countLabel.textAlignment = NSTextAlignmentRight;
    [header addSubview:self.countLabel];
    [self updateFilterButton];

    return header;
}

- (NSArray<PCCameraPark *> *)loadBundledCatalog {
    NSURL *manifestURL = [[NSBundle mainBundle] URLForResource:@"ParkCamsManifest" withExtension:@"json"];
    NSData *data = manifestURL ? [NSData dataWithContentsOfURL:manifestURL] : nil;
    if (data.length == 0) return @[];
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *parkDictionaries = [manifest[@"parks"] isKindOfClass:[NSArray class]] ? manifest[@"parks"] : @[];
    NSMutableArray *parks = [NSMutableArray arrayWithCapacity:parkDictionaries.count];
    for (NSDictionary *parkDictionary in parkDictionaries) {
        PCCameraPark *park = [PCCameraPark parkWithDictionary:parkDictionary];
        if (park) [parks addObject:park];
    }
    return parks;
}

- (NSArray<PCCameraPark *> *)buildCatalog {
    NSArray<PCCameraPark *> *bundled = [self loadBundledCatalog];
    if (bundled.count) return bundled;

    return @[
        [PCCameraPark parkWithName:@"Acadia" code:@"acad" region:@"Maine" category:@"Water" detail:@"Jordan Pond, Frenchman Bay, and air quality views." webcamURL:@"https://www.nps.gov/acad/learn/photosmultimedia/webcams.htm" feedCount:2],
        [PCCameraPark parkWithName:@"Arches" code:@"arch" region:@"Utah" category:@"Scenic" detail:@"Entrance road cameras for current desert conditions." webcamURL:@"https://www.nps.gov/arch/learn/photosmultimedia/webcams.htm" feedCount:2],
        [PCCameraPark parkWithName:@"Big Bend" code:@"bibe" region:@"Texas" category:@"Scenic" detail:@"Panther Junction view across the Chihuahuan Desert." webcamURL:@"https://www.nps.gov/bibe/learn/photosmultimedia/webcams.htm" feedCount:1],
        [PCCameraPark parkWithName:@"Channel Islands" code:@"chis" region:@"California" category:@"Water" detail:@"Anacapa Island ocean camera and kelp forest stream." webcamURL:@"https://www.nps.gov/chis/learn/photosmultimedia/ocean-webcam.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Crater Lake" code:@"crla" region:@"Oregon" category:@"Water" detail:@"Lake, entrance, and park headquarters snow cameras." webcamURL:@"https://www.nps.gov/crla/learn/photosmultimedia/webcams.htm" feedCount:3],
        [PCCameraPark parkWithName:@"Denali" code:@"dena" region:@"Alaska" category:@"Wildlife" detail:@"Seasonal puppy cam, depot, grizzly, Wonder Lake, and FAA views." webcamURL:@"https://www.nps.gov/dena/learn/photosmultimedia/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Everglades" code:@"ever" region:@"Florida" category:@"Wildlife" detail:@"Royal Palm and Anhinga Trail wildlife camera media." webcamURL:@"https://www.nps.gov/ever/learn/photosmultimedia/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Gateway Arch" code:@"jeff" region:@"Missouri" category:@"Scenic" detail:@"Partner cameras from the top of the arch facing east and west." webcamURL:@"https://www.nps.gov/jeff/learn/photosmultimedia/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Glacier" code:@"glac" region:@"Montana" category:@"Scenic" detail:@"River, entrance, Logan Pass, Many Glacier, and night sky views." webcamURL:@"https://www.nps.gov/glac/learn/photosmultimedia/webcams.htm" feedCount:14],
        [PCCameraPark parkWithName:@"Grand Canyon" code:@"grca" region:@"Arizona" category:@"Scenic" detail:@"South Rim, Yavapai, trailhead, and regional road cameras." webcamURL:@"https://www.nps.gov/grca/learn/photosmultimedia/webcams.htm" feedCount:9],
        [PCCameraPark parkWithName:@"Great Smoky Mountains" code:@"grsm" region:@"North Carolina, Tennessee" category:@"Scenic" detail:@"Kuwohi, Newfound Gap, Purchase Knob, and Look Rock." webcamURL:@"https://www.nps.gov/grsm/learn/photosmultimedia/webcams.htm" feedCount:4],
        [PCCameraPark parkWithName:@"Hawaii Volcanoes" code:@"havo" region:@"Hawaii" category:@"Volcano" detail:@"USGS volcano research cameras inside the park." webcamURL:@"https://www.nps.gov/havo/learn/photosmultimedia/webcams.htm" feedCount:16],
        [PCCameraPark parkWithName:@"Katmai" code:@"katm" region:@"Alaska" category:@"Wildlife" detail:@"Brooks Falls, river, riffles, mountain, and bear cams." webcamURL:@"https://www.nps.gov/katm/learn/photosmultimedia/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Lassen Volcanic" code:@"lavo" region:@"California" category:@"Volcano" detail:@"Kohm Yah-mah-nee Visitor Center and Manzanita Lake camera page." webcamURL:@"https://www.nps.gov/lavo/learn/photosmultimedia/webcams.htm" feedCount:1],
        [PCCameraPark parkWithName:@"Mammoth Cave" code:@"maca" region:@"Kentucky" category:@"Scenic" detail:@"Green River Bluffs air quality and weather camera." webcamURL:@"https://www.nps.gov/maca/learn/photosmultimedia/webcams.htm" feedCount:1],
        [PCCameraPark parkWithName:@"Mesa Verde" code:@"meve" region:@"Colorado" category:@"Scenic" detail:@"Spruce Tree House and dust monitoring views." webcamURL:@"https://www.nps.gov/meve/learn/photosmultimedia/webcam.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Mount Rainier" code:@"mora" region:@"Washington" category:@"Scenic" detail:@"Paradise, Longmire, high camp, air quality, and Sunrise views." webcamURL:@"https://www.nps.gov/mora/learn/photosmultimedia/webcams.htm" feedCount:7],
        [PCCameraPark parkWithName:@"Olympic" code:@"olym" region:@"Washington" category:@"Water" detail:@"Hurricane Ridge, Kalaloch, First Beach, and Lake Crescent." webcamURL:@"https://www.nps.gov/olym/learn/photosmultimedia/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Petrified Forest" code:@"pefo" region:@"Arizona" category:@"Scenic" detail:@"Painted Desert Inn view over the Painted Desert." webcamURL:@"https://www.nps.gov/pefo/learn/photosmultimedia/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Redwood" code:@"redw" region:@"California" category:@"Wildlife" detail:@"Kuchel Visitor Center, Elk Prairie, Jedediah Smith, and Bald Hills." webcamURL:@"https://www.nps.gov/redw/learn/photosmultimedia/webcams.htm" feedCount:4],
        [PCCameraPark parkWithName:@"Rocky Mountain" code:@"romo" region:@"Colorado" category:@"Scenic" detail:@"Entrance, Alpine Visitor Center, Kawuneeche, Longs Peak, and Divide." webcamURL:@"https://www.nps.gov/romo/learn/photosmultimedia/webcams.htm" feedCount:6],
        [PCCameraPark parkWithName:@"Sequoia and Kings Canyon" code:@"seki" region:@"California" category:@"Scenic" detail:@"Giant Forest air quality camera and regional fire lookout links." webcamURL:@"https://www.nps.gov/seki/learn/photosmultimedia/webcams.htm" feedCount:1],
        [PCCameraPark parkWithName:@"Shenandoah" code:@"shen" region:@"Virginia" category:@"Scenic" detail:@"Mountain View Cam from the Pinnacles area toward Luray." webcamURL:@"https://www.nps.gov/media/webcam/view.htm?id=81B46B71-1DD8-B71B-0B55074571E08B1E" feedCount:1],
        [PCCameraPark parkWithName:@"Wrangell-St. Elias" code:@"wrst" region:@"Alaska" category:@"Scenic" detail:@"Wrangell Mountains, Kennecott Mill, and Kennicott Glacier views." webcamURL:@"https://www.nps.gov/thingstodo/webcams.htm" feedCount:0],
        [PCCameraPark parkWithName:@"Yellowstone" code:@"yell" region:@"Idaho, Montana, Wyoming" category:@"Scenic" detail:@"Old Faithful live stream plus entrance and geyser basin cameras." webcamURL:@"https://www.nps.gov/yell/learn/photosmultimedia/webcams.htm" feedCount:10],
        [PCCameraPark parkWithName:@"Yosemite" code:@"yose" region:@"California" category:@"Water" detail:@"Yosemite Falls, Half Dome, high country, ski area, and river views." webcamURL:@"https://www.nps.gov/yose/learn/photosmultimedia/webcams.htm" feedCount:3],
        [PCCameraPark parkWithName:@"Zion" code:@"zion" region:@"Utah" category:@"Scenic" detail:@"Temples and Towers of the Virgin from Zion Canyon." webcamURL:@"https://www.nps.gov/zion/learn/photosmultimedia/webcams.htm" feedCount:1]
    ];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilters];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)filterTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Filter parks" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *categories = @[@"All", @"Scenic", @"Wildlife", @"Water", @"Volcano"];
    for (NSString *category in categories) {
        [sheet addAction:[UIAlertAction actionWithTitle:category style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.selectedCategory = category;
            [self updateFilterButton];
            [self applyFilters];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.filterButton;
    sheet.popoverPresentationController.sourceRect = self.filterButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)updateFilterButton {
    NSString *title = [self.selectedCategory isEqualToString:@"All"] ? @"Filter" : self.selectedCategory;
    [self.filterButton setTitle:title forState:UIControlStateNormal];
    CGFloat alpha = [self.selectedCategory isEqualToString:@"All"] ? 0.08 : 0.18;
    self.filterButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:alpha];
}

- (void)applyFilters {
    NSString *query = [self.searchBar.text lowercaseString];
    NSString *category = self.selectedCategory ?: @"All";
    NSMutableArray *matches = [NSMutableArray array];
    for (PCCameraPark *park in self.parks) {
        BOOL categoryOK = [category isEqualToString:@"All"] || [park.category isEqualToString:category];
        NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@ %@", park.name, park.region, park.category, park.detail] lowercaseString];
        BOOL searchOK = query.length == 0 || [haystack rangeOfString:query].location != NSNotFound;
        if (categoryOK && searchOK) [matches addObject:park];
    }
    self.filteredParks = matches;
    [self.tableView reloadData];
    [self updateCountLabel];
}

- (void)updateCountLabel {
    NSInteger feeds = 0;
    for (PCCameraPark *park in self.filteredParks) feeds += park.feedCount;
    self.countLabel.text = [NSString stringWithFormat:@"%ld parks  |  %ld working feeds", (long)self.filteredParks.count, (long)feeds];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredParks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PCCameraCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CameraCell" forIndexPath:indexPath];
    [cell configureWithPark:self.filteredParks[indexPath.row]];
    return cell;
}

- (void)startSlideshow {
    NSArray<PCCameraPark *> *source = self.filteredParks.count ? self.filteredParks : self.parks;
    PCSlideshowViewController *slideshow = [[PCSlideshowViewController alloc] initWithParks:source];
    [self.navigationController pushViewController:slideshow animated:YES];
}

- (void)startSocialFeed {
    NSArray<PCCameraPark *> *source = self.filteredParks.count ? self.filteredParks : self.parks;
    if (source.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No parks loaded"
                                                                       message:@"The park catalog is not ready yet."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    PCSocialFeedViewController *controller = [[PCSocialFeedViewController alloc] initWithParks:source];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PCFeedListViewController *feeds = [[PCFeedListViewController alloc] initWithPark:self.filteredParks[indexPath.row]];
    [self.navigationController pushViewController:feeds animated:YES];
}

@end
