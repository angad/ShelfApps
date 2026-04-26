#import <Foundation/Foundation.h>
#import "CCCamera.h"

typedef void (^CCCameraCatalogCompletion)(NSArray<CCCamera *> *cameras, NSString *statusText);
typedef void (^CCCameraCatalogProgress)(NSUInteger completedProviders, NSUInteger totalProviders, NSString *providerName);
typedef void (^CCCameraProviderCompletion)(NSArray<CCCamera *> *cameras, NSError *error);

@protocol CCCameraProvider <NSObject>

@property (nonatomic, readonly) NSString *displayName;
- (void)fetchCamerasWithCompletion:(CCCameraProviderCompletion)completion;

@end

@interface CCCameraCatalog : NSObject

@property (nonatomic, copy, readonly) NSArray<CCCamera *> *cameras;
@property (nonatomic, copy, readonly) NSString *statusText;
@property (nonatomic, strong, readonly) NSDate *lastRefreshDate;

+ (instancetype)sharedCatalog;
+ (NSArray<NSDictionary *> *)allStates;
- (NSArray<CCCamera *> *)loadCachedCameras;
- (void)refreshWithCompletion:(CCCameraCatalogCompletion)completion;
- (void)refreshWithProgress:(CCCameraCatalogProgress)progress completion:(CCCameraCatalogCompletion)completion;
- (void)refreshIfNeededWithCompletion:(CCCameraCatalogCompletion)completion;
- (void)refreshInBackgroundIfNeededWithCompletion:(CCCameraCatalogCompletion)completion;
- (void)refreshInBackgroundIfNeededWithProgress:(CCCameraCatalogProgress)progress completion:(CCCameraCatalogCompletion)completion;
- (BOOL)needsRefresh;

@end
