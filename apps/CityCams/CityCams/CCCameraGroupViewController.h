#import <UIKit/UIKit.h>
#import "CCCamera.h"

typedef NS_ENUM(NSInteger, CCCameraGroupMode) {
    CCCameraGroupModeCity = 0,
    CCCameraGroupModeSource = 1
};

@interface CCCameraGroupViewController : UIViewController

- (instancetype)initWithTitle:(NSString *)title cameras:(NSArray<CCCamera *> *)cameras mode:(CCCameraGroupMode)mode;

@end
