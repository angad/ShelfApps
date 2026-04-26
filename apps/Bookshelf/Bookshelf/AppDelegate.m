#import "AppDelegate.h"
#import "BookshelfViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    BookshelfViewController *bookshelf = [[BookshelfViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:bookshelf];
    navigation.navigationBar.translucent = NO;
    navigation.navigationBar.barTintColor = [UIColor colorWithRed:0.15 green:0.10 blue:0.07 alpha:1.0];
    navigation.navigationBar.tintColor = [UIColor colorWithRed:0.78 green:0.60 blue:0.34 alpha:1.0];
    navigation.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.96 green:0.91 blue:0.82 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]
    };
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

@end
