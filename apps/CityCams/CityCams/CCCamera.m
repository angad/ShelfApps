#import "CCCamera.h"

static NSString *CCStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

@implementation CCCamera

+ (instancetype)cameraWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    CCCamera *camera = [[CCCamera alloc] init];
    camera.identifier = CCStringValue(dictionary[@"identifier"]);
    camera.stateCode = CCStringValue(dictionary[@"stateCode"]);
    camera.stateName = CCStringValue(dictionary[@"stateName"]);
    camera.city = CCStringValue(dictionary[@"city"]);
    camera.sourceName = CCStringValue(dictionary[@"sourceName"]);
    camera.sourceIdentifier = CCStringValue(dictionary[@"sourceIdentifier"]);
    camera.title = CCStringValue(dictionary[@"title"]);
    camera.subtitle = CCStringValue(dictionary[@"subtitle"]);
    camera.imageURL = CCStringValue(dictionary[@"imageURL"]);
    camera.streamURL = CCStringValue(dictionary[@"streamURL"]);
    camera.sourceURL = CCStringValue(dictionary[@"sourceURL"]);
    camera.updatedText = CCStringValue(dictionary[@"updatedText"]);
    camera.latitude = [dictionary[@"latitude"] doubleValue];
    camera.longitude = [dictionary[@"longitude"] doubleValue];
    camera.feedType = [dictionary[@"feedType"] integerValue];
    return camera;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"identifier": self.identifier ?: @"",
        @"stateCode": self.stateCode ?: @"",
        @"stateName": self.stateName ?: @"",
        @"city": self.city ?: @"",
        @"sourceName": self.sourceName ?: @"",
        @"sourceIdentifier": self.sourceIdentifier ?: @"",
        @"title": self.title ?: @"",
        @"subtitle": self.subtitle ?: @"",
        @"imageURL": self.imageURL ?: @"",
        @"streamURL": self.streamURL ?: @"",
        @"sourceURL": self.sourceURL ?: @"",
        @"updatedText": self.updatedText ?: @"",
        @"latitude": @(self.latitude),
        @"longitude": @(self.longitude),
        @"feedType": @(self.feedType)
    };
}

- (NSString *)feedTypeLabel {
    switch (self.feedType) {
        case CCCameraFeedTypeHLS:
            return @"LIVE HLS";
        case CCCameraFeedTypeExternal:
            return @"SOURCE";
        case CCCameraFeedTypeImage:
        default:
            return @"IMAGE";
    }
}

- (BOOL)hasPlayableStream {
    return self.streamURL.length > 0 && [self.streamURL rangeOfString:@".m3u8" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

@end
