#import <UIKit/UIKit.h>

@interface BKImageLoader : NSObject

+ (instancetype)sharedLoader;
- (void)loadImageWithURLString:(NSString *)urlString completion:(void (^)(UIImage *image))completion;

@end
