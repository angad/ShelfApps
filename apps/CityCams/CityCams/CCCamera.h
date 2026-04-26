#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CCCameraFeedType) {
    CCCameraFeedTypeImage = 0,
    CCCameraFeedTypeHLS = 1,
    CCCameraFeedTypeExternal = 2
};

@interface CCCamera : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *stateCode;
@property (nonatomic, copy) NSString *stateName;
@property (nonatomic, copy) NSString *city;
@property (nonatomic, copy) NSString *sourceName;
@property (nonatomic, copy) NSString *sourceIdentifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *imageURL;
@property (nonatomic, copy) NSString *streamURL;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic, copy) NSString *updatedText;
@property (nonatomic) double latitude;
@property (nonatomic) double longitude;
@property (nonatomic) CCCameraFeedType feedType;

+ (instancetype)cameraWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
- (NSString *)feedTypeLabel;
- (BOOL)hasPlayableStream;

@end
