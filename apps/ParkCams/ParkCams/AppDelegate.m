#import "AppDelegate.h"
#import "ParkCamsViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    ParkCamsViewController *root = [[ParkCamsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.translucent = NO;
    nav.navigationBar.barTintColor = [UIColor colorWithRed:0.055 green:0.125 blue:0.145 alpha:1.0];
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.98 green:0.82 blue:0.43 alpha:1.0];
    nav.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.98 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
