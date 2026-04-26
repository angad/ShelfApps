#import "AppDelegate.h"
#import "CityCamsViewController.h"
#import "CCCameraCatalog.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    CityCamsViewController *root = [[CityCamsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.translucent = NO;
    nav.navigationBar.barTintColor = [UIColor colorWithRed:0.04 green:0.10 blue:0.13 alpha:1.0];
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.36 green:0.86 blue:0.84 alpha:1.0];
    nav.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.98 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack]
    };

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    [application setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
    return YES;
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    [[CCCameraCatalog sharedCatalog] loadCachedCameras];
    if (![[CCCameraCatalog sharedCatalog] needsRefresh]) {
        completionHandler(UIBackgroundFetchResultNoData);
        return;
    }
    [[CCCameraCatalog sharedCatalog] refreshWithCompletion:^(NSArray<CCCamera *> *cameras, NSString *statusText) {
        completionHandler(cameras.count ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData);
    }];
}

@end
