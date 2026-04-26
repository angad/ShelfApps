#import "BKImageLoader.h"
#import <CommonCrypto/CommonDigest.h>
#import <string.h>

@interface BKImageLoader ()

@property (nonatomic, strong) NSCache *memoryCache;
@property (nonatomic, strong) NSURLSession *session;

@end

@implementation BKImageLoader

+ (instancetype)sharedLoader {
    static BKImageLoader *loader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loader = [[BKImageLoader alloc] initPrivate];
    });
    return loader;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        self.memoryCache = [[NSCache alloc] init];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 12.0;
        configuration.timeoutIntervalForResource = 20.0;
        self.session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)loadImageWithURLString:(NSString *)urlString completion:(void (^)(UIImage *image))completion {
    if (urlString.length == 0) {
        if (completion) {
            completion(nil);
        }
        return;
    }

    UIImage *cached = [self.memoryCache objectForKey:urlString];
    if (cached) {
        if (completion) {
            completion(cached);
        }
        return;
    }

    NSString *path = [self cachePathForURLString:urlString];
    NSData *diskData = [NSData dataWithContentsOfFile:path];
    UIImage *diskImage = diskData ? [UIImage imageWithData:diskData] : nil;
    if (diskImage) {
        [self.memoryCache setObject:diskImage forKey:urlString];
        if (completion) {
            completion(diskImage);
        }
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) {
            completion(nil);
        }
        return;
    }

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = nil;
        if (data.length > 0 && !error) {
            image = [UIImage imageWithData:data];
            if (image) {
                [self.memoryCache setObject:image forKey:urlString];
                [data writeToFile:path atomically:YES];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(image);
            }
        });
    }];
    [task resume];
}

- (NSString *)cachePathForURLString:(NSString *)urlString {
    NSArray *directories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *directory = [[directories firstObject] stringByAppendingPathComponent:@"BookCovers"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    const char *input = [urlString UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(input, (CC_LONG)strlen(input), digest);
    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02x", digest[i]];
    }
    return [directory stringByAppendingPathComponent:[hash stringByAppendingString:@".jpg"]];
}

@end
