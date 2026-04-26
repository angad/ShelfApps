#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface BKBook : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *isbn;
@property (nonatomic, copy) NSString *year;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *shelf;
@property (nonatomic, copy) NSString *conditionText;
@property (nonatomic, copy) NSString *note;
@property (nonatomic, copy) NSString *borrowerName;
@property (nonatomic, copy) NSString *coverImageURL;
@property (nonatomic, copy) NSString *goodreadsBookURL;
@property (nonatomic, copy) NSString *goodreadsAverageRating;
@property (nonatomic, copy) NSString *goodreadsRatingsCount;
@property (nonatomic, copy) NSString *resalePrice;
@property (nonatomic, copy) NSString *resaleVendor;
@property (nonatomic, copy) NSString *resaleURL;
@property (nonatomic, copy) NSString *resalePriceUpdatedAt;
@property (nonatomic, copy) NSString *resalePriceError;
@property (nonatomic, copy) NSString *coverColorHex;

+ (instancetype)bookWithDictionary:(NSDictionary *)dictionary;
+ (NSArray<BKBook *> *)seedBooks;
+ (BKBook *)catalogBookForISBN:(NSString *)isbn;
- (NSDictionary *)dictionaryValue;
- (UIColor *)coverColor;

@end
