#import <UIKit/UIKit.h>

@protocol ScannerViewControllerDelegate <NSObject>

- (void)scannerDidAddBook;

@end

@interface ScannerViewController : UIViewController

@property (nonatomic, weak) id<ScannerViewControllerDelegate> delegate;

@end
