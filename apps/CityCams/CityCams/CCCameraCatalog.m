#import "CCCameraCatalog.h"

static NSString * const CCCameraCacheKey = @"CityCamsCameraCacheV3";
static NSString * const CCCameraCacheDateKey = @"CityCamsCameraCacheDateV3";
static NSTimeInterval const CCCameraMinimumRefreshInterval = 24.0 * 60.0 * 60.0;

typedef NS_ENUM(NSInteger, CCConfiguredParserType) {
    CCConfiguredParserTypeGeoJSON = 0,
    CCConfiguredParserTypeArcGIS = 1,
    CCConfiguredParserTypeDelDOT = 2,
    CCConfiguredParserTypeMichigan = 3,
    CCConfiguredParserTypeMoDOT = 4,
    CCConfiguredParserTypeNewMexico = 5,
    CCConfiguredParserTypeOhio = 6,
    CCConfiguredParserTypeFlorida = 7,
    CCConfiguredParserTypeNorthCarolina = 8,
    CCConfiguredParserTypeOregon = 9
};

static NSString *CCCleanString(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return text ?: @"";
    }
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static BOOL CCBoolValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        return [lower isEqualToString:@"true"] || [lower isEqualToString:@"1"] || [lower isEqualToString:@"yes"];
    }
    return NO;
}

static NSString *CCValueOrFallback(NSString *value, NSString *fallback) {
    return value.length ? value : fallback;
}

static NSString *CCFirstString(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        NSString *value = CCCleanString(dictionary[key]);
        if (value.length) return value;
    }
    return @"";
}

static NSString *CCStripHTML(NSString *text) {
    if (text.length == 0) return @"";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    NSString *stripped = [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    return [stripped stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *CCFirstRegexGroup(NSString *text, NSString *pattern) {
    if (text.length == 0) return @"";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return @"";
    return [text substringWithRange:[match rangeAtIndex:1]];
}

static NSString *CCAbsoluteURL(NSString *value, NSString *baseURL) {
    NSString *text = CCCleanString(value);
    if (text.length == 0) return @"";
    if ([text hasPrefix:@"http://"] || [text hasPrefix:@"https://"]) return text;
    if ([text hasPrefix:@"/"] && baseURL.length) return [baseURL stringByAppendingString:text];
    return text;
}

static NSArray *CCJSONArrayFromData(NSData *data, NSError **error) {
    if (data.length == 0) return @[];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if ([json isKindOfClass:[NSArray class]]) return json;
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSArray *dataArray = json[@"data"];
        if ([dataArray isKindOfClass:[NSArray class]]) return dataArray;
        NSArray *features = json[@"features"];
        if ([features isKindOfClass:[NSArray class]]) return features;
    }
    return @[];
}

static NSArray *CCArrayAtPath(id root, NSArray<NSString *> *keys) {
    id current = root;
    for (NSString *key in keys) {
        if (![current isKindOfClass:[NSDictionary class]]) return @[];
        current = current[key];
    }
    return [current isKindOfClass:[NSArray class]] ? current : @[];
}

static NSString *CCStateNameForCode(NSString *code) {
    for (NSDictionary *state in [CCCameraCatalog allStates]) {
        if ([state[@"code"] isEqualToString:code]) return state[@"name"];
    }
    return code ?: @"";
}

static NSString *CCCaltransDistrictName(NSInteger district) {
    NSDictionary *names = @{
        @1: @"Caltrans D1 North Coast",
        @2: @"Caltrans D2 Northern CA",
        @3: @"Caltrans D3 Sacramento",
        @4: @"Caltrans D4 Bay Area",
        @5: @"Caltrans D5 Central Coast",
        @6: @"Caltrans D6 Central Valley",
        @7: @"Caltrans D7 Los Angeles",
        @8: @"Caltrans D8 Inland Empire",
        @9: @"Caltrans D9 Eastern Sierra",
        @10: @"Caltrans D10 Stockton",
        @11: @"Caltrans D11 San Diego",
        @12: @"Caltrans D12 Orange County"
    };
    return names[@(district)] ?: [NSString stringWithFormat:@"Caltrans D%ld", (long)district];
}

@interface CCVirginia511Provider : NSObject <CCCameraProvider>
@end

@interface CCConfiguredProvider : NSObject <CCCameraProvider>

@property (nonatomic, copy) NSString *stateCode;
@property (nonatomic, copy) NSString *stateName;
@property (nonatomic, copy) NSString *sourceName;
@property (nonatomic, copy) NSString *sourceIdentifier;
@property (nonatomic, copy) NSString *endpointURL;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic) CCConfiguredParserType parserType;

+ (instancetype)providerWithStateCode:(NSString *)stateCode sourceName:(NSString *)sourceName sourceIdentifier:(NSString *)sourceIdentifier endpointURL:(NSString *)endpointURL sourceURL:(NSString *)sourceURL parserType:(CCConfiguredParserType)parserType;

@end

@implementation CCConfiguredProvider

+ (instancetype)providerWithStateCode:(NSString *)stateCode sourceName:(NSString *)sourceName sourceIdentifier:(NSString *)sourceIdentifier endpointURL:(NSString *)endpointURL sourceURL:(NSString *)sourceURL parserType:(CCConfiguredParserType)parserType {
    CCConfiguredProvider *provider = [[CCConfiguredProvider alloc] init];
    provider.stateCode = stateCode;
    provider.stateName = CCStateNameForCode(stateCode);
    provider.sourceName = sourceName;
    provider.sourceIdentifier = sourceIdentifier;
    provider.endpointURL = endpointURL;
    provider.sourceURL = sourceURL;
    provider.parserType = parserType;
    return provider;
}

- (NSString *)displayName {
    return self.sourceName;
}

- (void)fetchCamerasWithCompletion:(CCCameraProviderCompletion)completion {
    NSURL *url = [NSURL URLWithString:self.endpointURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [request setValue:@"CityCams/1.0 iOS" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) completion(@[], error);
            return;
        }
        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSArray *cameras = jsonError ? @[] : [self camerasFromJSONObject:json];
        if (completion) completion(cameras, jsonError);
    }] resume];
}

- (NSArray<CCCamera *> *)camerasFromJSONObject:(id)json {
    switch (self.parserType) {
        case CCConfiguredParserTypeArcGIS:
            return [self parseArcGIS:json];
        case CCConfiguredParserTypeDelDOT:
            return [self parseDelDOT:json];
        case CCConfiguredParserTypeMichigan:
            return [self parseMichigan:json];
        case CCConfiguredParserTypeMoDOT:
            return [self parseMoDOT:json];
        case CCConfiguredParserTypeNewMexico:
            return [self parseNewMexico:json];
        case CCConfiguredParserTypeOhio:
            return [self parseOhio:json];
        case CCConfiguredParserTypeFlorida:
            return [self parseFlorida:json];
        case CCConfiguredParserTypeNorthCarolina:
            return [self parseNorthCarolina:json];
        case CCConfiguredParserTypeOregon:
            return [self parseOregon:json];
        case CCConfiguredParserTypeGeoJSON:
        default:
            return [self parseGeoJSON:json];
    }
}

- (CCCamera *)baseCameraWithIdentifier:(NSString *)identifier title:(NSString *)title city:(NSString *)city imageURL:(NSString *)imageURL streamURL:(NSString *)streamURL latitude:(double)latitude longitude:(double)longitude subtitle:(NSString *)subtitle {
    if (imageURL.length == 0 && streamURL.length == 0) return nil;
    CCCamera *camera = [[CCCamera alloc] init];
    camera.identifier = [NSString stringWithFormat:@"%@-%@", self.sourceIdentifier ?: self.stateCode, identifier.length ? identifier : title];
    camera.stateCode = self.stateCode;
    camera.stateName = self.stateName;
    camera.city = CCValueOrFallback(city, self.stateName);
    camera.sourceName = self.sourceName;
    camera.sourceIdentifier = self.sourceIdentifier;
    camera.title = CCValueOrFallback(title, @"Camera");
    camera.subtitle = subtitle ?: @"";
    camera.imageURL = imageURL ?: @"";
    camera.streamURL = streamURL ?: @"";
    camera.sourceURL = self.sourceURL;
    camera.feedType = [camera hasPlayableStream] ? CCCameraFeedTypeHLS : CCCameraFeedTypeImage;
    camera.latitude = latitude;
    camera.longitude = longitude;
    return camera;
}

- (NSArray<CCCamera *> *)parseGeoJSON:(id)json {
    NSArray *features = [json isKindOfClass:[NSDictionary class]] ? json[@"features"] : nil;
    if (![features isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *feature in features) {
        NSDictionary *properties = [feature isKindOfClass:[NSDictionary class]] ? feature[@"properties"] : nil;
        NSDictionary *geometry = [feature isKindOfClass:[NSDictionary class]] ? feature[@"geometry"] : nil;
        if (![properties isKindOfClass:[NSDictionary class]]) continue;
        NSArray *coordinates = [geometry isKindOfClass:[NSDictionary class]] ? geometry[@"coordinates"] : nil;
        double longitude = ([coordinates isKindOfClass:[NSArray class]] && coordinates.count >= 2) ? [coordinates[0] doubleValue] : 0;
        double latitude = ([coordinates isKindOfClass:[NSArray class]] && coordinates.count >= 2) ? [coordinates[1] doubleValue] : 0;

        NSArray *nested = properties[@"cameras"];
        if (![nested isKindOfClass:[NSArray class]] || nested.count == 0) nested = properties[@"Cameras"];
        if ([nested isKindOfClass:[NSArray class]] && nested.count) {
            for (NSDictionary *item in nested) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *title = CCValueOrFallback(CCFirstString(item, @[@"description", @"name", @"Description"]), CCFirstString(properties, @[@"description", @"name"]));
                NSString *imageURL = CCFirstString(item, @[@"image", @"image_url", @"LinkPath", @"FullPath"]);
                NSString *identifier = CCValueOrFallback(CCFirstString(item, @[@"id", @"ID", @"Description"]), CCFirstString(properties, @[@"id", @"ObjectID"]));
                NSString *city = CCFirstString(properties, @[@"jurisdiction", @"Region"]);
                NSString *subtitle = CCValueOrFallback(CCFirstString(item, @[@"Direction", @"direction"]), CCFirstString(properties, @[@"route", @"Route"]));
                CCCamera *camera = [self baseCameraWithIdentifier:identifier title:title city:city imageURL:imageURL streamURL:@"" latitude:latitude longitude:longitude subtitle:subtitle];
                if (camera) [cameras addObject:camera];
            }
            continue;
        }

        if (!CCBoolValue(properties[@"active"]) && properties[@"active"] != nil) continue;
        if (CCBoolValue(properties[@"problem_stream"])) continue;
        NSString *streamURL = CCValueOrFallback(CCCleanString(properties[@"ios_url"]), CCCleanString(properties[@"https_url"]));
        NSString *imageURL = CCCleanString(properties[@"image_url"]);
        NSString *title = CCValueOrFallback(CCCleanString(properties[@"description"]), CCCleanString(properties[@"name"]));
        NSString *subtitle = [@[CCCleanString(properties[@"route"]), CCCleanString(properties[@"direction"])] componentsJoinedByString:@" "];
        CCCamera *camera = [self baseCameraWithIdentifier:CCValueOrFallback(CCCleanString(properties[@"id"]), CCCleanString(properties[@"name"])) title:title city:CCCleanString(properties[@"jurisdiction"]) imageURL:imageURL streamURL:streamURL latitude:latitude longitude:longitude subtitle:subtitle];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseArcGIS:(id)json {
    NSArray *features = [json isKindOfClass:[NSDictionary class]] ? json[@"features"] : nil;
    if (![features isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *feature in features) {
        NSDictionary *attributes = feature[@"attributes"];
        NSDictionary *geometry = feature[@"geometry"];
        if (![attributes isKindOfClass:[NSDictionary class]]) continue;
        NSString *imageURL = CCFirstString(attributes, @[@"ImageURL", @"SnapShot", @"snapshot", @"CCVEWebURL", @"SmallURL", @"LargeURL"]);
        NSString *streamURL = CCFirstString(attributes, @[@"VideoURL", @"videoURL", @"StreamURL"]);
        NSString *title = CCFirstString(attributes, @[@"ImageName", @"CameraLocation", @"description", @"Description", @"name", @"Location"]);
        NSString *city = CCFirstString(attributes, @[@"county", @"County", @"city", @"City", @"district"]);
        NSString *identifier = CCFirstString(attributes, @[@"OBJECTID", @"FID", @"id", @"ID"]);
        double longitude = [CCFirstString(attributes, @[@"longitude", @"Longitude", @"x"]) doubleValue];
        double latitude = [CCFirstString(attributes, @[@"latitude", @"Latitude", @"y"]) doubleValue];
        if ([geometry isKindOfClass:[NSDictionary class]]) {
            longitude = [CCCleanString(geometry[@"x"]) doubleValue] ?: longitude;
            latitude = [CCCleanString(geometry[@"y"]) doubleValue] ?: latitude;
        }
        CCCamera *camera = [self baseCameraWithIdentifier:identifier title:title city:city imageURL:imageURL streamURL:streamURL latitude:latitude longitude:longitude subtitle:CCFirstString(attributes, @[@"highway", @"CameraDirection", @"direction"])];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseFlorida:(id)json {
    NSArray *items = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
    if (![items isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSArray *images = item[@"images"];
        if (![images isKindOfClass:[NSArray class]]) continue;
        NSString *point = CCCleanString([item valueForKeyPath:@"latLng.geography.wellKnownText"]);
        NSString *pointBody = CCFirstRegexGroup(point, @"POINT\\s*\\(([^\\)]+)\\)");
        NSArray *parts = [pointBody componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *numbers = [NSMutableArray array];
        for (NSString *part in parts) {
            if (part.length) [numbers addObject:part];
        }
        double longitude = numbers.count >= 2 ? [numbers[0] doubleValue] : 0;
        double latitude = numbers.count >= 2 ? [numbers[1] doubleValue] : 0;
        NSString *city = CCFirstString(item, @[@"city", @"county", @"region"]);
        NSString *subtitle = [[@[CCCleanString(item[@"roadway"]), CCCleanString(item[@"direction"]), CCCleanString(item[@"county"])] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *text, NSDictionary *bindings) {
            return text.length > 0;
        }]] componentsJoinedByString:@" "];
        for (NSDictionary *image in images) {
            if (![image isKindOfClass:[NSDictionary class]]) continue;
            if (CCBoolValue(image[@"disabled"]) || CCBoolValue(image[@"blocked"])) continue;
            NSString *imageURL = CCAbsoluteURL(image[@"imageUrl"], @"https://fl511.com");
            NSString *title = CCValueOrFallback(CCCleanString(item[@"location"]), CCValueOrFallback(CCCleanString(image[@"description"]), @"FL511 Camera"));
            NSString *identifier = CCValueOrFallback(CCCleanString(image[@"id"]), CCCleanString(item[@"id"]));
            CCCamera *camera = [self baseCameraWithIdentifier:identifier title:title city:city imageURL:imageURL streamURL:@"" latitude:latitude longitude:longitude subtitle:subtitle];
            if (camera) [cameras addObject:camera];
        }
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseNorthCarolina:(id)json {
    if (![json isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *item in (NSArray *)json) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (![CCCleanString(item[@"status"]) isEqualToString:@"OK"]) continue;
        NSString *imageURL = CCCleanString(item[@"imageURL"]);
        NSString *title = CCValueOrFallback(CCCleanString(item[@"locationName"]), CCCleanString(item[@"displayName"]));
        NSString *subtitle = CCCleanString(item[@"mileMarker"]).length ? [NSString stringWithFormat:@"Mile %@", CCCleanString(item[@"mileMarker"])] : @"";
        CCCamera *camera = [self baseCameraWithIdentifier:CCCleanString(item[@"id"]) title:title city:@"North Carolina" imageURL:imageURL streamURL:@"" latitude:[CCCleanString(item[@"latitude"]) doubleValue] longitude:[CCCleanString(item[@"longitude"]) doubleValue] subtitle:subtitle];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseOregon:(id)json {
    NSArray *features = [json isKindOfClass:[NSDictionary class]] ? json[@"features"] : nil;
    if (![features isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *feature in features) {
        NSDictionary *attributes = feature[@"attributes"];
        if (![attributes isKindOfClass:[NSDictionary class]]) continue;
        NSString *filename = CCCleanString(attributes[@"filename"]);
        NSString *imageURL = filename.length ? [@"https://tripcheck.com/RoadCams/cams/" stringByAppendingString:filename] : @"";
        CCCamera *camera = [self baseCameraWithIdentifier:CCCleanString(attributes[@"cameraId"]) title:CCCleanString(attributes[@"title"]) city:@"Oregon" imageURL:imageURL streamURL:@"" latitude:[CCCleanString(attributes[@"latitude"]) doubleValue] longitude:[CCCleanString(attributes[@"longitude"]) doubleValue] subtitle:CCCleanString(attributes[@"route"])];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseDelDOT:(id)json {
    NSArray *items = CCArrayAtPath(json, @[@"videoCameras"]);
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSDictionary *urls = item[@"urls"];
        if (![item isKindOfClass:[NSDictionary class]] || !CCBoolValue(item[@"enabled"])) continue;
        NSString *streamURL = [urls isKindOfClass:[NSDictionary class]] ? CCValueOrFallback(CCCleanString(urls[@"m3u8s"]), CCCleanString(urls[@"m3u8"])) : @"";
        CCCamera *camera = [self baseCameraWithIdentifier:CCCleanString(item[@"id"]) title:CCCleanString(item[@"title"]) city:CCCleanString(item[@"county"]) imageURL:@"" streamURL:streamURL latitude:[CCCleanString(item[@"lat"]) doubleValue] longitude:[CCCleanString(item[@"lon"]) doubleValue] subtitle:CCCleanString(item[@"status"])];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseMichigan:(id)json {
    if (![json isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSDictionary *item in (NSArray *)json) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *imageURL = CCFirstRegexGroup(CCCleanString(item[@"image"]), @"src=\\\"([^\\\"]+)\\\"");
        NSString *title = [NSString stringWithFormat:@"%@ %@", CCCleanString(item[@"route"]), CCCleanString(item[@"location"])];
        NSString *city = CCStripHTML(CCCleanString(item[@"county"]));
        CCCamera *camera = [self baseCameraWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)index++] title:title city:city imageURL:imageURL streamURL:@"" latitude:0 longitude:0 subtitle:CCCleanString(item[@"direction"])];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseMoDOT:(id)json {
    if (![json isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSDictionary *item in (NSArray *)json) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *streamURL = CCCleanString(item[@"html"]);
        CCCamera *camera = [self baseCameraWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)index++] title:CCCleanString(item[@"location"]) city:@"Missouri" imageURL:@"" streamURL:streamURL latitude:[CCCleanString(item[@"y"]) doubleValue] longitude:[CCCleanString(item[@"x"]) doubleValue] subtitle:@""];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseNewMexico:(id)json {
    NSArray *items = CCArrayAtPath(json, @[@"cameraInfo"]);
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]] || !CCBoolValue(item[@"enabled"])) continue;
        CCCamera *camera = [self baseCameraWithIdentifier:CCCleanString(item[@"name"]) title:CCCleanString(item[@"title"]) city:CCCleanString(item[@"grouping"]) imageURL:CCCleanString(item[@"snapshotFile"]) streamURL:@"" latitude:[CCCleanString(item[@"lat"]) doubleValue] longitude:[CCCleanString(item[@"lon"]) doubleValue] subtitle:[NSString stringWithFormat:@"District %@", CCCleanString(item[@"district"])]];
        if (camera) [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray<CCCamera *> *)parseOhio:(id)json {
    if (![json isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *cameras = [NSMutableArray array];
    for (NSDictionary *item in (NSArray *)json) {
        NSArray *views = item[@"Cameras"];
        if (![views isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *view in views) {
            if (![view isKindOfClass:[NSDictionary class]]) continue;
            NSString *imageURL = CCValueOrFallback(CCCleanString(view[@"LargeURL"]), CCCleanString(view[@"SmallURL"]));
            NSString *title = CCValueOrFallback(CCCleanString(item[@"Description"]), CCCleanString(item[@"Location"]));
            NSString *identifier = [NSString stringWithFormat:@"%@-%@", CCCleanString(item[@"Id"]), CCCleanString(view[@"Direction"])];
            CCCamera *camera = [self baseCameraWithIdentifier:identifier title:title city:@"Ohio" imageURL:imageURL streamURL:@"" latitude:[CCCleanString(item[@"Latitude"]) doubleValue] longitude:[CCCleanString(item[@"Longitude"]) doubleValue] subtitle:CCCleanString(view[@"Direction"])];
            if (camera) [cameras addObject:camera];
        }
    }
    return cameras;
}

@end

@implementation CCVirginia511Provider

- (NSString *)displayName {
    return @"Virginia 511 / VDOT";
}

- (void)fetchCamerasWithCompletion:(CCCameraProviderCompletion)completion {
    NSURL *url = [NSURL URLWithString:@"https://511.vdot.virginia.gov/services/map/layers/map/cams"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [request setValue:@"CityCams/1.0 iOS" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) completion(@[], error);
            return;
        }
        NSError *jsonError = nil;
        NSArray *features = CCJSONArrayFromData(data, &jsonError);
        NSMutableArray *cameras = [NSMutableArray array];
        for (NSDictionary *feature in features) {
            NSDictionary *properties = [feature isKindOfClass:[NSDictionary class]] ? feature[@"properties"] : nil;
            NSDictionary *geometry = [feature isKindOfClass:[NSDictionary class]] ? feature[@"geometry"] : nil;
            if (![properties isKindOfClass:[NSDictionary class]]) continue;
            if (!CCBoolValue(properties[@"active"]) || CCBoolValue(properties[@"problem_stream"])) continue;

            NSString *streamURL = CCCleanString(properties[@"ios_url"]);
            if (streamURL.length == 0) streamURL = CCCleanString(properties[@"https_url"]);
            NSString *imageURL = CCCleanString(properties[@"image_url"]);
            if (streamURL.length == 0 && imageURL.length == 0) continue;

            CCCamera *camera = [[CCCamera alloc] init];
            camera.identifier = [@"vdot-" stringByAppendingString:CCValueOrFallback(CCCleanString(properties[@"id"]), CCCleanString(properties[@"name"]))];
            camera.stateCode = @"VA";
            camera.stateName = @"Virginia";
            camera.city = CCValueOrFallback(CCCleanString(properties[@"jurisdiction"]), @"Virginia");
            camera.sourceName = self.displayName;
            camera.sourceIdentifier = @"vdot-511";
            camera.title = CCValueOrFallback(CCCleanString(properties[@"description"]), CCValueOrFallback(CCCleanString(properties[@"name"]), @"VDOT Camera"));
            camera.subtitle = [@[CCCleanString(properties[@"route"]), CCCleanString(properties[@"direction"])] componentsJoinedByString:@" "];
            camera.imageURL = imageURL;
            camera.streamURL = streamURL;
            camera.sourceURL = @"https://511.vdot.virginia.gov/";
            camera.feedType = [camera hasPlayableStream] ? CCCameraFeedTypeHLS : CCCameraFeedTypeImage;
            NSArray *coordinates = [geometry isKindOfClass:[NSDictionary class]] ? geometry[@"coordinates"] : nil;
            if ([coordinates isKindOfClass:[NSArray class]] && coordinates.count >= 2) {
                camera.longitude = [coordinates[0] doubleValue];
                camera.latitude = [coordinates[1] doubleValue];
            }
            [cameras addObject:camera];
        }
        if (completion) completion(cameras, jsonError);
    }] resume];
}

@end

@interface CCCaltransProvider : NSObject <CCCameraProvider>
@end

@implementation CCCaltransProvider

- (NSString *)displayName {
    return @"California Caltrans";
}

- (void)fetchCamerasWithCompletion:(CCCameraProviderCompletion)completion {
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray *allCameras = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];
    for (NSInteger district = 1; district <= 12; district++) {
        dispatch_group_enter(group);
        NSString *urlString = [NSString stringWithFormat:@"https://cwwp2.dot.ca.gov/data/d%ld/cctv/cctvStatusD%02ld.json", (long)district, (long)district];
        NSURL *url = [NSURL URLWithString:urlString];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
        [request setValue:@"CityCams/1.0 iOS" forHTTPHeaderField:@"User-Agent"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                @synchronized (errors) {
                    [errors addObject:error];
                }
                dispatch_group_leave(group);
                return;
            }
            NSError *jsonError = nil;
            NSArray *items = CCJSONArrayFromData(data, &jsonError);
            NSMutableArray *districtCameras = [NSMutableArray array];
            for (NSDictionary *item in items) {
                NSDictionary *cctv = [item isKindOfClass:[NSDictionary class]] ? item[@"cctv"] : nil;
                if (![cctv isKindOfClass:[NSDictionary class]]) continue;
                if (!CCBoolValue(cctv[@"inService"])) continue;
                NSDictionary *location = cctv[@"location"];
                NSDictionary *imageData = cctv[@"imageData"];
                NSDictionary *staticData = [imageData isKindOfClass:[NSDictionary class]] ? imageData[@"static"] : nil;
                if (![location isKindOfClass:[NSDictionary class]] || ![imageData isKindOfClass:[NSDictionary class]]) continue;

                NSString *imageURL = [staticData isKindOfClass:[NSDictionary class]] ? CCCleanString(staticData[@"currentImageURL"]) : @"";
                NSString *streamURL = CCCleanString(imageData[@"streamingVideoURL"]);
                if (imageURL.length == 0 && streamURL.length == 0) continue;

                NSString *index = CCCleanString(cctv[@"index"]);
                NSString *name = CCValueOrFallback(CCCleanString(location[@"locationName"]), @"Caltrans Camera");
                CCCamera *camera = [[CCCamera alloc] init];
                camera.identifier = [NSString stringWithFormat:@"caltrans-d%ld-%@", (long)district, CCValueOrFallback(index, name)];
                camera.stateCode = @"CA";
                camera.stateName = @"California";
                camera.city = CCValueOrFallback(CCCleanString(location[@"nearbyPlace"]), CCValueOrFallback(CCCleanString(location[@"county"]), @"California"));
                camera.sourceName = CCCaltransDistrictName(district);
                camera.sourceIdentifier = [NSString stringWithFormat:@"caltrans-d%ld", (long)district];
                camera.title = name;
                camera.subtitle = [@[CCCleanString(location[@"route"]), CCCleanString(location[@"direction"]), CCCleanString(location[@"county"])] componentsJoinedByString:@" "];
                camera.imageURL = imageURL;
                camera.streamURL = streamURL;
                camera.sourceURL = @"https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm";
                camera.feedType = [camera hasPlayableStream] ? CCCameraFeedTypeHLS : CCCameraFeedTypeImage;
                camera.latitude = [CCCleanString(location[@"latitude"]) doubleValue];
                camera.longitude = [CCCleanString(location[@"longitude"]) doubleValue];
                NSDictionary *timestamp = cctv[@"recordTimestamp"];
                if ([timestamp isKindOfClass:[NSDictionary class]]) {
                    NSString *date = CCCleanString(timestamp[@"recordDate"]);
                    NSString *time = CCCleanString(timestamp[@"recordTime"]);
                    camera.updatedText = [@[date, time] componentsJoinedByString:@" "];
                }
                [districtCameras addObject:camera];
            }
            @synchronized (allCameras) {
                [allCameras addObjectsFromArray:districtCameras];
            }
            if (jsonError) {
                @synchronized (errors) {
                    [errors addObject:jsonError];
                }
            }
            dispatch_group_leave(group);
        }] resume];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *firstError = nil;
        @synchronized (errors) {
            firstError = errors.firstObject;
        }
        NSArray *snapshot = nil;
        @synchronized (allCameras) {
            snapshot = [allCameras copy];
        }
        if (completion) completion(snapshot ?: @[], firstError);
    });
}

@end

@interface CCCameraCatalog ()

@property (nonatomic, copy) NSArray<id<CCCameraProvider>> *providers;
@property (nonatomic, copy, readwrite) NSArray<CCCamera *> *cameras;
@property (nonatomic, copy, readwrite) NSString *statusText;
@property (nonatomic, strong, readwrite) NSDate *lastRefreshDate;

@end

@implementation CCCameraCatalog

+ (instancetype)sharedCatalog {
    static CCCameraCatalog *catalog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalog = [[CCCameraCatalog alloc] init];
        catalog.providers = @[
            [[CCVirginia511Provider alloc] init],
            [[CCCaltransProvider alloc] init],
            [CCConfiguredProvider providerWithStateCode:@"DE" sourceName:@"DelDOT Traffic Cameras" sourceIdentifier:@"deldot" endpointURL:@"https://tmc.deldot.gov/json/videocamera.json" sourceURL:@"https://deldot.gov/Traffic/travel_advisory/" parserType:CCConfiguredParserTypeDelDOT],
            [CCConfiguredProvider providerWithStateCode:@"FL" sourceName:@"FL511 Cameras" sourceIdentifier:@"fl511" endpointURL:@"https://fl511.com/List/GetData/Cameras?query=%7B%22columns%22%3A%5B%7B%22data%22%3Anull%2C%22name%22%3A%22%22%7D%2C%7B%22name%22%3A%22sortId%22%2C%22s%22%3Atrue%7D%2C%7B%22name%22%3A%22region%22%2C%22s%22%3Atrue%7D%2C%7B%22name%22%3A%22county%22%2C%22s%22%3Atrue%7D%2C%7B%22name%22%3A%22roadway%22%2C%22s%22%3Atrue%7D%2C%7B%22data%22%3A5%2C%22name%22%3A%22description2%22%7D%2C%7B%22data%22%3A6%2C%22name%22%3A%22%22%7D%5D%2C%22order%22%3A%5B%7B%22column%22%3A1%2C%22dir%22%3A%22asc%22%7D%2C%7B%22column%22%3A2%2C%22dir%22%3A%22asc%22%7D%5D%2C%22start%22%3A0%2C%22length%22%3A5000%2C%22search%22%3A%7B%22value%22%3A%22%22%7D%7D&lang=en" sourceURL:@"https://fl511.com/" parserType:CCConfiguredParserTypeFlorida],
            [CCConfiguredProvider providerWithStateCode:@"IA" sourceName:@"Iowa DOT Cameras" sourceIdentifier:@"iowa-dot" endpointURL:@"https://services.arcgis.com/8lRhdTsQyJpO52F1/arcgis/rest/services/Traffic_Cameras_View/FeatureServer/0/query?where=1%3D1&outFields=ImageName%2CImageURL%2CVideoURL&returnGeometry=true&outSR=4326&f=pjson" sourceURL:@"https://www.511ia.org/" parserType:CCConfiguredParserTypeArcGIS],
            [CCConfiguredProvider providerWithStateCode:@"IL" sourceName:@"Travel Midwest Cameras" sourceIdentifier:@"travel-midwest-il" endpointURL:@"https://services2.arcgis.com/aIrBD8yn1TDTEXoz/arcgis/rest/services/TrafficCamerasTM_Public/FeatureServer/0/query?where=y+%3E+0&outFields=*&returnGeometry=true&f=pjson" sourceURL:@"https://www.travelmidwest.com/" parserType:CCConfiguredParserTypeArcGIS],
            [CCConfiguredProvider providerWithStateCode:@"KY" sourceName:@"Kentucky Traffic Cameras" sourceIdentifier:@"kentucky-cameras" endpointURL:@"https://services2.arcgis.com/CcI36Pduqd0OR4W9/arcgis/rest/services/trafficCamerasCur_Prd/FeatureServer/0/query?where=id+%3E+0&outFields=*&returnGeometry=true&f=pjson" sourceURL:@"https://goky.ky.gov/" parserType:CCConfiguredParserTypeArcGIS],
            [CCConfiguredProvider providerWithStateCode:@"MI" sourceName:@"MDOT Mi Drive Cameras" sourceIdentifier:@"mi-drive" endpointURL:@"https://mdotjboss.state.mi.us/MiDrive//camera/list" sourceURL:@"https://mdotjboss.state.mi.us/MiDrive/map" parserType:CCConfiguredParserTypeMichigan],
            [CCConfiguredProvider providerWithStateCode:@"MO" sourceName:@"MoDOT Traveler Cameras" sourceIdentifier:@"modot" endpointURL:@"https://traveler.modot.org/timconfig/feed/desktop/StreamingCams2.json" sourceURL:@"https://traveler.modot.org/map/" parserType:CCConfiguredParserTypeMoDOT],
            [CCConfiguredProvider providerWithStateCode:@"MT" sourceName:@"Montana 511 Cameras" sourceIdentifier:@"montana-511" endpointURL:@"https://mt.cdn.iteris-atis.com/geojson/icons/metadata/icons.cameras.geojson" sourceURL:@"https://www.511mt.net/" parserType:CCConfiguredParserTypeGeoJSON],
            [CCConfiguredProvider providerWithStateCode:@"NC" sourceName:@"DriveNC Cameras" sourceIdentifier:@"drivenc" endpointURL:@"https://eapps.ncdot.gov/services/traffic-prod/v1/cameras?verbose=true" sourceURL:@"https://drivenc.gov/" parserType:CCConfiguredParserTypeNorthCarolina],
            [CCConfiguredProvider providerWithStateCode:@"ND" sourceName:@"NDDOT Travel Information Cameras" sourceIdentifier:@"nddot" endpointURL:@"https://travelfiles.dot.nd.gov/geojson_nc/cameras.json" sourceURL:@"https://travel.dot.nd.gov/" parserType:CCConfiguredParserTypeGeoJSON],
            [CCConfiguredProvider providerWithStateCode:@"NM" sourceName:@"New Mexico Roads Cameras" sourceIdentifier:@"nmroads" endpointURL:@"https://servicev4.nmroads.com/RealMapWAR//GetCameraInfo" sourceURL:@"https://nmroads.com/" parserType:CCConfiguredParserTypeNewMexico],
            [CCConfiguredProvider providerWithStateCode:@"OH" sourceName:@"OHGO Cameras" sourceIdentifier:@"ohgo" endpointURL:@"https://api.ohgo.com/roadmarkers/cameras" sourceURL:@"https://www.ohgo.com/" parserType:CCConfiguredParserTypeOhio],
            [CCConfiguredProvider providerWithStateCode:@"OR" sourceName:@"Oregon TripCheck Cameras" sourceIdentifier:@"tripcheck" endpointURL:@"https://www.tripcheck.com/Scripts/map/data/cctvinventory.js" sourceURL:@"https://www.tripcheck.com/" parserType:CCConfiguredParserTypeOregon],
            [CCConfiguredProvider providerWithStateCode:@"SC" sourceName:@"South Carolina 511 Cameras" sourceIdentifier:@"sc-511" endpointURL:@"https://sc.cdn.iteris-atis.com/geojson/icons/metadata/icons.cameras.geojson" sourceURL:@"https://www.511sc.org/" parserType:CCConfiguredParserTypeGeoJSON],
            [CCConfiguredProvider providerWithStateCode:@"SD" sourceName:@"South Dakota 511 Cameras" sourceIdentifier:@"sd-511" endpointURL:@"https://sd.cdn.iteris-atis.com/geojson/icons/metadata/icons.cameras.geojson" sourceURL:@"https://sd511.org/" parserType:CCConfiguredParserTypeGeoJSON]
        ];
        catalog.cameras = @[];
        catalog.statusText = @"Ready";
    });
    return catalog;
}

+ (NSArray<NSDictionary *> *)allStates {
    static NSArray *states;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = @[
            @{@"code": @"AL", @"name": @"Alabama"}, @{@"code": @"AK", @"name": @"Alaska"}, @{@"code": @"AZ", @"name": @"Arizona"}, @{@"code": @"AR", @"name": @"Arkansas"}, @{@"code": @"CA", @"name": @"California"},
            @{@"code": @"CO", @"name": @"Colorado"}, @{@"code": @"CT", @"name": @"Connecticut"}, @{@"code": @"DE", @"name": @"Delaware"}, @{@"code": @"FL", @"name": @"Florida"}, @{@"code": @"GA", @"name": @"Georgia"},
            @{@"code": @"HI", @"name": @"Hawaii"}, @{@"code": @"ID", @"name": @"Idaho"}, @{@"code": @"IL", @"name": @"Illinois"}, @{@"code": @"IN", @"name": @"Indiana"}, @{@"code": @"IA", @"name": @"Iowa"},
            @{@"code": @"KS", @"name": @"Kansas"}, @{@"code": @"KY", @"name": @"Kentucky"}, @{@"code": @"LA", @"name": @"Louisiana"}, @{@"code": @"ME", @"name": @"Maine"}, @{@"code": @"MD", @"name": @"Maryland"},
            @{@"code": @"MA", @"name": @"Massachusetts"}, @{@"code": @"MI", @"name": @"Michigan"}, @{@"code": @"MN", @"name": @"Minnesota"}, @{@"code": @"MS", @"name": @"Mississippi"}, @{@"code": @"MO", @"name": @"Missouri"},
            @{@"code": @"MT", @"name": @"Montana"}, @{@"code": @"NE", @"name": @"Nebraska"}, @{@"code": @"NV", @"name": @"Nevada"}, @{@"code": @"NH", @"name": @"New Hampshire"}, @{@"code": @"NJ", @"name": @"New Jersey"},
            @{@"code": @"NM", @"name": @"New Mexico"}, @{@"code": @"NY", @"name": @"New York"}, @{@"code": @"NC", @"name": @"North Carolina"}, @{@"code": @"ND", @"name": @"North Dakota"}, @{@"code": @"OH", @"name": @"Ohio"},
            @{@"code": @"OK", @"name": @"Oklahoma"}, @{@"code": @"OR", @"name": @"Oregon"}, @{@"code": @"PA", @"name": @"Pennsylvania"}, @{@"code": @"RI", @"name": @"Rhode Island"}, @{@"code": @"SC", @"name": @"South Carolina"},
            @{@"code": @"SD", @"name": @"South Dakota"}, @{@"code": @"TN", @"name": @"Tennessee"}, @{@"code": @"TX", @"name": @"Texas"}, @{@"code": @"UT", @"name": @"Utah"}, @{@"code": @"VT", @"name": @"Vermont"},
            @{@"code": @"VA", @"name": @"Virginia"}, @{@"code": @"WA", @"name": @"Washington"}, @{@"code": @"WV", @"name": @"West Virginia"}, @{@"code": @"WI", @"name": @"Wisconsin"}, @{@"code": @"WY", @"name": @"Wyoming"}
        ];
    });
    return states;
}

- (NSArray<CCCamera *> *)loadCachedCameras {
    NSArray *cached = [[NSUserDefaults standardUserDefaults] objectForKey:CCCameraCacheKey];
    NSMutableArray *cameras = [NSMutableArray array];
    if ([cached isKindOfClass:[NSArray class]]) {
        for (NSDictionary *dictionary in cached) {
            CCCamera *camera = [CCCamera cameraWithDictionary:dictionary];
            if (camera) [cameras addObject:camera];
        }
    }
    self.cameras = [self sortedCameras:cameras];
    self.lastRefreshDate = [[NSUserDefaults standardUserDefaults] objectForKey:CCCameraCacheDateKey];
    if (self.cameras.count) {
        self.statusText = [NSString stringWithFormat:@"Loaded %lu cached cameras", (unsigned long)self.cameras.count];
    }
    return self.cameras;
}

- (void)refreshWithCompletion:(CCCameraCatalogCompletion)completion {
    [self refreshWithProgress:nil completion:completion];
}

- (void)refreshWithProgress:(CCCameraCatalogProgress)progress completion:(CCCameraCatalogCompletion)completion {
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray *allCameras = [NSMutableArray array];
    NSMutableArray *failedProviders = [NSMutableArray array];
    NSObject *progressLock = [[NSObject alloc] init];
    NSUInteger totalProviders = self.providers.count;
    __block NSUInteger completedProviders = 0;

    if (progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(0, totalProviders, @"Starting refresh");
        });
    }

    for (id<CCCameraProvider> provider in self.providers) {
        dispatch_group_enter(group);
        [provider fetchCamerasWithCompletion:^(NSArray<CCCamera *> *cameras, NSError *error) {
            if (cameras.count) {
                @synchronized (allCameras) {
                    [allCameras addObjectsFromArray:cameras];
                }
            }
            if (error) {
                @synchronized (failedProviders) {
                    [failedProviders addObject:provider.displayName ?: @"Provider"];
                }
            }
            if (progress) {
                NSUInteger currentCompleted = 0;
                @synchronized (progressLock) {
                    completedProviders++;
                    currentCompleted = completedProviders;
                }
                NSString *providerName = provider.displayName ?: @"Provider";
                dispatch_async(dispatch_get_main_queue(), ^{
                    progress(currentCompleted, totalProviders, providerName);
                });
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *sorted = [self sortedCameras:allCameras];
        self.cameras = sorted;
        self.lastRefreshDate = [NSDate date];
        NSMutableArray *serialized = [NSMutableArray arrayWithCapacity:sorted.count];
        for (CCCamera *camera in sorted) {
            [serialized addObject:[camera dictionaryRepresentation]];
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:serialized forKey:CCCameraCacheKey];
        [defaults setObject:self.lastRefreshDate forKey:CCCameraCacheDateKey];
        [defaults synchronize];

        NSUInteger liveCount = 0;
        for (CCCamera *camera in sorted) {
            if (camera.feedType == CCCameraFeedTypeHLS) liveCount++;
        }
        if (failedProviders.count) {
            self.statusText = [NSString stringWithFormat:@"%lu cameras, %lu live. Failed: %@", (unsigned long)sorted.count, (unsigned long)liveCount, [failedProviders componentsJoinedByString:@", "]];
        } else {
            self.statusText = [NSString stringWithFormat:@"%lu cameras, %lu live HLS", (unsigned long)sorted.count, (unsigned long)liveCount];
        }
        if (completion) completion(self.cameras, self.statusText);
    });
}

- (BOOL)needsRefresh {
    if (!self.lastRefreshDate) {
        self.lastRefreshDate = [[NSUserDefaults standardUserDefaults] objectForKey:CCCameraCacheDateKey];
    }
    if (!self.lastRefreshDate) return YES;
    return [[NSDate date] timeIntervalSinceDate:self.lastRefreshDate] >= CCCameraMinimumRefreshInterval;
}

- (void)refreshIfNeededWithCompletion:(CCCameraCatalogCompletion)completion {
    if (![self needsRefresh]) {
        NSString *status = self.statusText.length ? self.statusText : @"Daily camera catalog is current";
        if (completion) completion(self.cameras ?: @[], status);
        return;
    }
    [self refreshWithCompletion:completion];
}

- (void)refreshInBackgroundIfNeededWithCompletion:(CCCameraCatalogCompletion)completion {
    [self refreshInBackgroundIfNeededWithProgress:nil completion:completion];
}

- (void)refreshInBackgroundIfNeededWithProgress:(CCCameraCatalogProgress)progress completion:(CCCameraCatalogCompletion)completion {
    if (![self needsRefresh]) {
        if (completion) completion(self.cameras ?: @[], self.statusText ?: @"Daily camera catalog is current");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self refreshWithProgress:progress completion:completion];
    });
}

- (NSArray<CCCamera *> *)sortedCameras:(NSArray<CCCamera *> *)cameras {
    return [cameras sortedArrayUsingComparator:^NSComparisonResult(CCCamera *a, CCCamera *b) {
        NSComparisonResult state = [a.stateName compare:b.stateName options:NSCaseInsensitiveSearch];
        if (state != NSOrderedSame) return state;
        NSComparisonResult city = [a.city compare:b.city options:NSCaseInsensitiveSearch];
        if (city != NSOrderedSame) return city;
        NSComparisonResult source = [a.sourceName compare:b.sourceName options:NSCaseInsensitiveSearch];
        if (source != NSOrderedSame) return source;
        return [a.title compare:b.title options:NSCaseInsensitiveSearch];
    }];
}

@end
