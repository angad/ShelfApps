#import <UIKit/UIKit.h>
#import "CCCamera.h"

@interface CCCameraListViewController : UIViewController

- (instancetype)initWithTitle:(NSString *)title cameras:(NSArray<CCCamera *> *)cameras;

@end
