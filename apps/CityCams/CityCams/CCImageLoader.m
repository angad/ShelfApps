#import "CCImageLoader.h"

@interface CCImageLoader ()

@property (nonatomic, strong) NSCache *imageCache;

@end

@implementation CCImageLoader

+ (instancetype)sharedLoader {
    static CCImageLoader *loader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loader = [[CCImageLoader alloc] init];
        loader.imageCache = [[NSCache alloc] init];
        loader.imageCache.countLimit = 180;
    });
    return loader;
}

- (void)loadImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion {
    if (url.length == 0) {
        if (completion) completion(nil);
        return;
    }
    UIImage *cached = [self.imageCache objectForKey:url];
    if (cached) {
        if (completion) completion(cached);
        return;
    }
    [self fetchImageAtURL:url cacheKey:url completion:completion];
}

- (void)refreshImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion {
    if (url.length == 0) {
        if (completion) completion(nil);
        return;
    }
    [self.imageCache removeObjectForKey:url];
    [self fetchImageAtURL:url cacheKey:url completion:completion];
}

- (void)fetchImageAtURL:(NSString *)url cacheKey:(NSString *)cacheKey completion:(void (^)(UIImage *image))completion {
    NSURL *requestURL = [NSURL URLWithString:url];
    if (!requestURL) {
        if (completion) completion(nil);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    [request setValue:@"CityCams/1.0 iOS" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        if (image && cacheKey.length) {
            [self.imageCache setObject:image forKey:cacheKey];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(image);
        });
    }] resume];
}

@end
