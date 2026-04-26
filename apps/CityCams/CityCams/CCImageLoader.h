#import <UIKit/UIKit.h>

@interface CCImageLoader : NSObject

+ (instancetype)sharedLoader;
- (void)loadImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion;
- (void)refreshImageAtURL:(NSString *)url completion:(void (^)(UIImage *image))completion;

@end
