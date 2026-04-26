#import <UIKit/UIKit.h>
#import "CCCamera.h"

@interface CCCameraStoryViewController : UIViewController

- (instancetype)initWithCameras:(NSArray<CCCamera *> *)cameras accountTitle:(NSString *)accountTitle accountSubtitle:(NSString *)accountSubtitle;

@end
