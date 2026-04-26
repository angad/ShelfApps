#import <Foundation/Foundation.h>
#import "BKBook.h"

@interface BKGoodreadsClient : NSObject

+ (instancetype)sharedClient;
- (void)enrichBook:(BKBook *)book completion:(void (^)(BOOL changed))completion;

@end
