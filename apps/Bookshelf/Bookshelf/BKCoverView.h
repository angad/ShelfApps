#import <UIKit/UIKit.h>
#import "BKBook.h"

@interface BKCoverView : UIView

- (void)configureWithBook:(BKBook *)book compact:(BOOL)compact;

@end
