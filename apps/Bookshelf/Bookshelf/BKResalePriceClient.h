#import <Foundation/Foundation.h>
#import "BKBook.h"

@interface BKResalePriceClient : NSObject

+ (instancetype)sharedClient;
+ (BOOL)isPricingModeEnabled;
+ (void)setPricingModeEnabled:(BOOL)enabled;
- (void)refreshBookIfNeeded:(BKBook *)book force:(BOOL)force completion:(void (^)(BOOL changed))completion;

@end
