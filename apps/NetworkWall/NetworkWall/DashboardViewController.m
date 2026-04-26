#import "DashboardViewController.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

typedef NS_ENUM(NSInteger, NWTab) {
    NWTabDashboard = 0,
    NWTabDevices = 1,
    NWTabHistory = 2,
    NWTabSettings = 3
};

static NSString * const NWHistoricalSamplesKey = @"NetworkWall.HistoricalSamples";
static NSString * const NWKnownDevicesKey = @"NetworkWall.KnownDevices";
static NSString * const NWRefreshIntervalKey = @"NetworkWall.RefreshInterval";
static const NSTimeInterval NWDefaultRefreshInterval = 60.0;

@interface NWDevice : NSObject

@property (nonatomic, copy) NSString *ip;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *mac;
@property (nonatomic, copy) NSString *vendor;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) NSArray<NSNumber *> *openPorts;
@property (nonatomic, copy) NSString *serviceHint;
@property (nonatomic, copy) NSString *source;
@property (nonatomic) NSInteger confidence;
@property (nonatomic) BOOL isNew;

@end

@implementation NWDevice
@end

@interface NWScanResult : NSObject

@property (nonatomic, copy) NSString *subnet;
@property (nonatomic, copy) NSString *gateway;
@property (nonatomic, strong) NSDate *scanDate;
@property (nonatomic, strong) NSArray<NWDevice *> *devices;
@property (nonatomic) NSInteger gatewayLatencyMs;
@property (nonatomic) BOOL gatewayOK;
@property (nonatomic) BOOL dnsOK;
@property (nonatomic) BOOL internetOK;
@property (nonatomic) NSInteger collectorCount;

@end

@implementation NWScanResult
@end

@interface NWMetricTile : UIView

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;

- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color;
- (void)updateValue:(NSString *)value subtitle:(NSString *)subtitle color:(UIColor *)color;

@end

@implementation NWMetricTile

- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.105 green:0.116 blue:0.126 alpha:1.0];
        self.layer.cornerRadius = 8.0;
        self.clipsToBounds = YES;

        UIStackView *stack = [[UIStackView alloc] init];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentLeading;
        stack.spacing = 1.0;
        stack.layoutMargins = UIEdgeInsetsMake(7, 10, 7, 10);
        stack.layoutMarginsRelativeArrangement = YES;
        [self addSubview:stack];

        self.titleLabel = [NWMetricTile labelWithSize:9 weight:UIFontWeightBlack color:[UIColor colorWithWhite:0.58 alpha:1.0]];
        self.valueLabel = [NWMetricTile labelWithSize:20 weight:UIFontWeightBlack color:color];
        self.subtitleLabel = [NWMetricTile labelWithSize:10 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.68 alpha:1.0]];

        self.titleLabel.text = [title uppercaseString];
        self.valueLabel.minimumScaleFactor = 0.65;
        self.valueLabel.adjustsFontSizeToFitWidth = YES;
        self.subtitleLabel.minimumScaleFactor = 0.7;
        self.subtitleLabel.adjustsFontSizeToFitWidth = YES;

        [stack addArrangedSubview:self.titleLabel];
        [stack addArrangedSubview:self.valueLabel];
        [stack addArrangedSubview:self.subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
        ]];
    }
    return self;
}

+ (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)updateValue:(NSString *)value subtitle:(NSString *)subtitle color:(UIColor *)color {
    self.valueLabel.text = value;
    self.subtitleLabel.text = subtitle;
    self.valueLabel.textColor = color;
}

@end

@interface NWHistoryChartView : UIView

@property (nonatomic, strong) NSArray<NSDictionary *> *samples;
@property (nonatomic, strong) UIColor *lineColor;

@end

@implementation NWHistoryChartView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.105 alpha:1.0];
        self.layer.cornerRadius = 8.0;
        self.clipsToBounds = YES;
        self.lineColor = [UIColor colorWithRed:0.16 green:0.77 blue:0.90 alpha:1.0];
    }
    return self;
}

- (void)setSamples:(NSArray<NSDictionary *> *)samples {
    _samples = samples;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, self.backgroundColor.CGColor);
    CGContextFillRect(ctx, rect);

    CGRect plot = CGRectInset(rect, 18.0, 18.0);
    plot.origin.y += 12.0;
    plot.size.height -= 18.0;

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.18 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    for (NSInteger i = 0; i < 4; i++) {
        CGFloat y = plot.origin.y + (plot.size.height / 3.0) * i;
        CGContextMoveToPoint(ctx, plot.origin.x, y);
        CGContextAddLineToPoint(ctx, CGRectGetMaxX(plot), y);
    }
    CGContextStrokePath(ctx);

    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.78 alpha:1.0]
    };
    [@"Devices Online" drawAtPoint:CGPointMake(16, 10) withAttributes:attrs];

    if (self.samples.count < 2) {
        NSDictionary *emptyAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1.0]
        };
        [@"Waiting for scans" drawInRect:CGRectInset(rect, 30, 48) withAttributes:emptyAttrs];
        return;
    }

    NSInteger maxValue = 1;
    for (NSDictionary *sample in self.samples) {
        maxValue = MAX(maxValue, [sample[@"count"] integerValue]);
    }

    UIBezierPath *path = [UIBezierPath bezierPath];
    for (NSUInteger i = 0; i < self.samples.count; i++) {
        NSInteger count = [self.samples[i][@"count"] integerValue];
        CGFloat x = plot.origin.x + ((CGFloat)i / (CGFloat)(self.samples.count - 1)) * plot.size.width;
        CGFloat y = CGRectGetMaxY(plot) - ((CGFloat)count / (CGFloat)maxValue) * plot.size.height;
        if (i == 0) {
            [path moveToPoint:CGPointMake(x, y)];
        } else {
            [path addLineToPoint:CGPointMake(x, y)];
        }
    }

    [self.lineColor setStroke];
    path.lineWidth = 4.0;
    path.lineJoinStyle = kCGLineJoinRound;
    path.lineCapStyle = kCGLineCapRound;
    [path stroke];

    NSDictionary *maxAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.58 alpha:1.0]
    };
    NSString *maxText = [NSString stringWithFormat:@"%ld peak", (long)maxValue];
    [maxText drawAtPoint:CGPointMake(CGRectGetMaxX(plot) - 58, 12) withAttributes:maxAttrs];
}

@end

@interface NWBonjourCollector : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *responses;
@property (nonatomic, strong) NSMutableArray<NSNetServiceBrowser *> *browsers;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *services;

- (NSDictionary<NSString *, NSString *> *)browseWithTimeout:(NSTimeInterval)timeout;

@end

@implementation NWBonjourCollector

- (instancetype)init {
    self = [super init];
    if (self) {
        _responses = [NSMutableDictionary dictionary];
        _browsers = [NSMutableArray array];
        _services = [NSMutableArray array];
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)browseWithTimeout:(NSTimeInterval)timeout {
    NSArray *types = @[
        @"_services._dns-sd._udp.",
        @"_airplay._tcp.", @"_raop._tcp.", @"_companion-link._tcp.",
        @"_googlecast._tcp.", @"_roku-ecp._tcp.", @"_plexmediasvr._tcp.",
        @"_hap._tcp.", @"_homekit._tcp.", @"_hue._tcp.", @"_sonos._tcp.",
        @"_ipp._tcp.", @"_printer._tcp.", @"_smb._tcp.", @"_afpovertcp._tcp.",
        @"_ssh._tcp.", @"_http._tcp.", @"_workstation._tcp.", @"_networkwall._tcp."
    ];

    for (NSString *type in types) {
        NSNetServiceBrowser *browser = [[NSNetServiceBrowser alloc] init];
        browser.delegate = self;
        [self.browsers addObject:browser];
        [browser searchForServicesOfType:type inDomain:@"local."];
    }

    NSDate *endDate = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:endDate] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
    }

    for (NSNetServiceBrowser *browser in self.browsers) {
        [browser stop];
        browser.delegate = nil;
    }
    for (NSNetService *service in self.services) {
        [service stop];
        service.delegate = nil;
    }

    return [self.responses copy];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    service.delegate = self;
    [self.services addObject:service];
    [service resolveWithTimeout:1.0];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSMutableArray *ips = [NSMutableArray array];
    for (NSData *addressData in sender.addresses) {
        const struct sockaddr *sockaddr = (const struct sockaddr *)addressData.bytes;
        if (sockaddr->sa_family != AF_INET) {
            continue;
        }
        const struct sockaddr_in *addr = (const struct sockaddr_in *)sockaddr;
        char buffer[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &addr->sin_addr, buffer, sizeof(buffer));
        [ips addObject:[NSString stringWithUTF8String:buffer]];
    }

    NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@ %@", sender.name ?: @"", sender.type ?: @"", sender.domain ?: @"", @(sender.port)] lowercaseString];
    for (NSString *ip in ips) {
        NSString *existing = self.responses[ip] ?: @"";
        self.responses[ip] = [existing stringByAppendingFormat:@" %@", hint];
    }
}

@end

@interface NWNetworkScanner : NSObject

- (void)scanWithCompletion:(void (^)(NWScanResult *result))completion;

@end

@implementation NWNetworkScanner

- (void)scanWithCompletion:(void (^)(NWScanResult *result))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *subnet = nil;
        NSString *gateway = nil;
        NSArray<NSString *> *hosts = [self localHostsWithSubnet:&subnet gateway:&gateway];
        NSMutableArray<NWDevice *> *devices = [NSMutableArray array];
        NSMutableSet<NSString *> *reachable = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *openPortsByIP = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *hintsByIP = [NSMutableDictionary dictionary];
        NSDictionary<NSString *, NSString *> *mdns = [[[NWBonjourCollector alloc] init] browseWithTimeout:1.35];
        for (NSString *ip in mdns.allKeys) {
            if ([self ip:ip isInsideHosts:hosts] || [ip isEqualToString:gateway]) {
                [reachable addObject:ip];
                hintsByIP[ip] = [self mergedHint:hintsByIP[ip] with:mdns[ip]];
            }
        }
        NSMutableDictionary<NSString *, NWDevice *> *collectorDevices = [[self collectorDevicesForGateway:gateway mdnsHints:mdns] mutableCopy];

        NSDate *start = [NSDate date];
        NSMutableArray<NSNumber *> *gatewayPorts = [NSMutableArray array];
        BOOL gatewayOK = gateway.length > 0 ? [self probeHost:gateway timeout:0.32 openPorts:gatewayPorts] : NO;
        NSInteger gatewayLatency = gatewayOK ? (NSInteger)round([[NSDate date] timeIntervalSinceDate:start] * 1000.0) : -1;
        if (gateway.length > 0 && gatewayPorts.count > 0) {
            openPortsByIP[gateway] = gatewayPorts;
        }

        NSDictionary<NSString *, NSString *> *ssdp = [self ssdpDiscoveryWithTimeout:1.15];
        for (NSString *ip in ssdp.allKeys) {
            if ([self ip:ip isInsideHosts:hosts] || [ip isEqualToString:gateway]) {
                [reachable addObject:ip];
                hintsByIP[ip] = [self mergedHint:hintsByIP[ip] with:ssdp[ip]];
            }
        }

        for (NSString *ip in collectorDevices.allKeys) {
            if ([self ip:ip isInsideHosts:hosts] || [ip isEqualToString:gateway]) {
                [reachable addObject:ip];
            }
        }

        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t gate = dispatch_semaphore_create(42);

        for (NSString *ip in hosts) {
            if ([ip isEqualToString:gateway]) {
                if (gatewayOK) {
                    [reachable addObject:ip];
                }
                continue;
            }
            dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSMutableArray<NSNumber *> *openPorts = [NSMutableArray array];
                BOOL ok = [self probeHost:ip timeout:0.18 openPorts:openPorts];
                if (ok) {
                    @synchronized (reachable) {
                        [reachable addObject:ip];
                        if (openPorts.count > 0) {
                            openPortsByIP[ip] = openPorts;
                        }
                    }
                }
                dispatch_semaphore_signal(gate);
            });
        }

        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16.0 * NSEC_PER_SEC)));

        NSDictionary<NSString *, NSString *> *arp = [self arpTable];
        for (NSString *ip in arp.allKeys) {
            if ([self ip:ip isInsideHosts:hosts] || [ip isEqualToString:gateway]) {
                [reachable addObject:ip];
            }
        }

        NSDictionary *known = [[NSUserDefaults standardUserDefaults] dictionaryForKey:NWKnownDevicesKey] ?: @{};
        NSMutableDictionary *updatedKnown = [known mutableCopy];

        NSArray *sorted = [reachable.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [@([self lastOctet:a]) compare:@([self lastOctet:b])];
        }];

        for (NSString *ip in sorted) {
            NWDevice *collectorDevice = collectorDevices[ip];
            NWDevice *device = collectorDevice ?: [[NWDevice alloc] init];
            device.ip = ip;
            if (device.mac.length == 0) {
                device.mac = arp[ip] ?: @"";
            }
            if (device.vendor.length == 0) {
                device.vendor = [self vendorForMAC:device.mac];
            }
            if (device.openPorts.count == 0) {
                device.openPorts = openPortsByIP[ip] ?: @[];
            }
            device.serviceHint = [self mergedHint:hintsByIP[ip] with:device.serviceHint];
            if (device.serviceHint.length == 0 && device.openPorts.count == 0 && ![ip isEqualToString:gateway]) {
                device.openPorts = [self deepFingerprintPortsForHost:ip timeout:0.10];
            }
            if (device.name.length == 0) {
                device.name = [self displayNameForIP:ip vendor:device.vendor serviceHint:device.serviceHint gateway:[ip isEqualToString:gateway]];
            }
            if (device.type.length == 0 || [device.type isEqualToString:@"Unknown"]) {
                device.type = [self typeForName:device.name vendor:device.vendor serviceHint:device.serviceHint openPorts:device.openPorts gateway:[ip isEqualToString:gateway]];
            }
            device.confidence = [self confidenceForDevice:device gateway:[ip isEqualToString:gateway]];
            device.source = collectorDevice ? @"collector" : [self sourceForDevice:device];
            [self applyKnownIdentityFromStore:known toDevice:device];
            device.isNew = ([self knownEntryForDevice:device store:known] == nil);
            if (device.isNew) {
                [self updateKnownStore:updatedKnown withDevice:device firstSeen:YES];
            } else {
                [self updateKnownStore:updatedKnown withDevice:device firstSeen:NO];
            }
            [devices addObject:device];
        }

        [[NSUserDefaults standardUserDefaults] setObject:updatedKnown forKey:NWKnownDevicesKey];

        NWScanResult *result = [[NWScanResult alloc] init];
        result.scanDate = [NSDate date];
        result.subnet = subnet ?: @"No Wi-Fi";
        result.gateway = gateway ?: @"";
        result.devices = devices;
        result.dnsOK = [self probeHost:@"1.1.1.1" port:53 timeout:0.55] || [self probeHost:@"8.8.8.8" port:53 timeout:0.55];
        result.internetOK = [self probeHost:@"1.1.1.1" port:443 timeout:0.65] || [self probeHost:@"8.8.8.8" port:443 timeout:0.65];
        result.gatewayOK = gatewayOK || [reachable containsObject:gateway] || result.dnsOK || result.internetOK;
        result.gatewayLatencyMs = gatewayLatency;
        result.collectorCount = collectorDevices.count;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(result);
            }
        });
    });
}

- (NSDictionary<NSString *, NWDevice *> *)collectorDevicesForGateway:(NSString *)gateway mdnsHints:(NSDictionary<NSString *, NSString *> *)mdnsHints {
    NSMutableDictionary<NSString *, NWDevice *> *devices = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *urls = [NSMutableArray arrayWithArray:@[
        @"http://networkwall.local:8765/devices.json",
        @"http://networkwall-collector.local:8765/devices.json"
    ]];
    if (gateway.length > 0) {
        [urls addObject:[NSString stringWithFormat:@"http://%@:8765/devices.json", gateway]];
    }
    for (NSString *ip in mdnsHints.allKeys) {
        NSString *hint = [mdnsHints[ip] lowercaseString];
        if ([hint containsString:@"_networkwall._tcp"] || [hint containsString:@"networkwall"]) {
            [urls addObject:[NSString stringWithFormat:@"http://%@:8765/devices.json", ip]];
        }
    }

    for (NSString *urlString in urls) {
        NSData *data = [self fetchURLString:urlString timeout:0.9];
        if (data.length == 0) {
            continue;
        }
        NSError *error = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (error || !json) {
            continue;
        }

        NSArray *rows = nil;
        if ([json isKindOfClass:[NSArray class]]) {
            rows = json;
        } else if ([json isKindOfClass:[NSDictionary class]]) {
            id value = json[@"devices"];
            if ([value isKindOfClass:[NSArray class]]) {
                rows = value;
            }
        }

        for (id row in rows) {
            if (![row isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NWDevice *device = [self deviceFromCollectorRow:(NSDictionary *)row];
            if (device.ip.length > 0) {
                devices[device.ip] = device;
            }
        }
    }
    return devices;
}

- (NSData *)fetchURLString:(NSString *)urlString timeout:(NSTimeInterval)timeout {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    request.HTTPMethod = @"GET";

    __block NSData *data = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = timeout;
    configuration.timeoutIntervalForResource = timeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (!error && (!http || (http.statusCode >= 200 && http.statusCode < 300))) {
            data = responseData;
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 0.25) * NSEC_PER_SEC)));
    [task cancel];
    [session finishTasksAndInvalidate];
    return data;
}

- (NWDevice *)deviceFromCollectorRow:(NSDictionary *)row {
    NWDevice *device = [[NWDevice alloc] init];
    device.ip = [self stringValue:row[@"ip"]];
    device.name = [self firstNonEmpty:@[[self stringValue:row[@"name"]], [self stringValue:row[@"hostname"]], [self stringValue:row[@"label"]]]];
    device.mac = [[self stringValue:row[@"mac"]] uppercaseString];
    device.vendor = [self firstNonEmpty:@[[self stringValue:row[@"vendor"]], [self vendorForMAC:device.mac]]];
    device.type = [self normalizedType:[self stringValue:row[@"type"]]];
    device.openPorts = [self portArrayFromValue:row[@"ports"]];
    device.serviceHint = [self firstNonEmpty:@[[self stringValue:row[@"services"]], [self stringValue:row[@"serviceHint"]], [self stringValue:row[@"fingerprint"]]]];
    device.source = @"collector";
    device.confidence = 95;
    return device;
}

- (NSString *)stringValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            NSString *part = [self stringValue:item];
            if (part.length > 0) {
                [parts addObject:part];
            }
        }
        return [parts componentsJoinedByString:@" "];
    }
    return @"";
}

- (NSString *)firstNonEmpty:(NSArray<NSString *> *)values {
    for (NSString *value in values) {
        if (value.length > 0) {
            return value;
        }
    }
    return @"";
}

- (NSArray<NSNumber *> *)portArrayFromValue:(id)value {
    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            NSInteger port = [[self stringValue:item] integerValue];
            if (port > 0) {
                [ports addObject:@(port)];
            }
        }
    } else if ([value isKindOfClass:[NSString class]]) {
        for (NSString *part in [(NSString *)value componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]]) {
            NSInteger port = [part integerValue];
            if (port > 0) {
                [ports addObject:@(port)];
            }
        }
    }
    return ports;
}

- (NSString *)mergedHint:(NSString *)a with:(NSString *)b {
    if (a.length == 0) return b ?: @"";
    if (b.length == 0) return a ?: @"";
    if ([a containsString:b]) return a;
    if ([b containsString:a]) return b;
    return [NSString stringWithFormat:@"%@ %@", a, b];
}

- (NSDictionary *)knownEntryForDevice:(NWDevice *)device store:(NSDictionary *)store {
    NSString *macKey = device.mac.length > 0 ? [NSString stringWithFormat:@"mac:%@", device.mac] : nil;
    NSString *ipKey = device.ip.length > 0 ? [NSString stringWithFormat:@"ip:%@", device.ip] : nil;
    NSDictionary *entry = macKey ? store[macKey] : nil;
    if (!entry && ipKey) {
        entry = store[ipKey];
    }
    if (!entry && device.ip.length > 0) {
        entry = store[device.ip];
    }
    return entry;
}

- (void)applyKnownIdentityFromStore:(NSDictionary *)store toDevice:(NWDevice *)device {
    NSDictionary *entry = [self knownEntryForDevice:device store:store];
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *manualName = [self stringValue:entry[@"manualName"]];
    NSString *bestName = [self stringValue:entry[@"name"]];
    NSString *bestType = [self stringValue:entry[@"type"]];
    NSString *bestVendor = [self stringValue:entry[@"vendor"]];
    NSInteger savedConfidence = [entry[@"confidence"] integerValue];

    if (manualName.length > 0) {
        device.name = manualName;
        device.confidence = MAX(device.confidence, 100);
    } else if ((device.name.length == 0 || [device.name hasPrefix:@"Device "]) && bestName.length > 0) {
        device.name = bestName;
    }
    if ((device.type.length == 0 || [device.type isEqualToString:@"Unknown"] || device.confidence < 45) && bestType.length > 0 && savedConfidence >= 45) {
        device.type = bestType;
        device.confidence = MAX(device.confidence, savedConfidence - 5);
    }
    if (device.vendor.length == 0 && bestVendor.length > 0) {
        device.vendor = bestVendor;
    }
}

- (void)updateKnownStore:(NSMutableDictionary *)store withDevice:(NWDevice *)device firstSeen:(BOOL)firstSeen {
    NSMutableDictionary *entry = [[self knownEntryForDevice:device store:store] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (entry[@"firstSeen"] == nil || firstSeen) {
        entry[@"firstSeen"] = @(now);
    }
    entry[@"lastSeen"] = @(now);
    if (device.name.length > 0) entry[@"name"] = device.name;
    if (device.type.length > 0) entry[@"type"] = device.type;
    if (device.vendor.length > 0) entry[@"vendor"] = device.vendor;
    if (device.mac.length > 0) entry[@"mac"] = device.mac;
    if (device.ip.length > 0) entry[@"lastIP"] = device.ip;
    entry[@"confidence"] = @(MAX(device.confidence, [entry[@"confidence"] integerValue]));
    if (device.source.length > 0) entry[@"source"] = device.source;

    if (device.mac.length > 0) {
        store[[NSString stringWithFormat:@"mac:%@", device.mac]] = entry;
    }
    if (device.ip.length > 0) {
        store[[NSString stringWithFormat:@"ip:%@", device.ip]] = entry;
    }
}

- (NSArray<NSString *> *)localHostsWithSubnet:(NSString **)subnet gateway:(NSString **)gateway {
    struct ifaddrs *ifaddr = NULL;
    NSMutableArray<NSString *> *hosts = [NSMutableArray array];

    if (getifaddrs(&ifaddr) != 0) {
        if (subnet) *subnet = @"No Wi-Fi";
        return hosts;
    }

    uint32_t ipHost = 0;
    uint32_t maskHost = 0;

    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if ((ifa->ifa_flags & IFF_UP) == 0 || (ifa->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
        if (![name isEqualToString:@"en0"]) {
            continue;
        }
        struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
        struct sockaddr_in *mask = (struct sockaddr_in *)ifa->ifa_netmask;
        ipHost = ntohl(addr->sin_addr.s_addr);
        maskHost = ntohl(mask->sin_addr.s_addr);
        break;
    }

    freeifaddrs(ifaddr);

    if (ipHost == 0 || maskHost == 0) {
        if (subnet) *subnet = @"No Wi-Fi";
        return hosts;
    }

    uint32_t network = ipHost & maskHost;
    uint32_t broadcast = network | ~maskHost;
    uint32_t hostCount = broadcast > network ? broadcast - network - 1 : 0;
    if (hostCount == 0 || hostCount > 254) {
        maskHost = 0xffffff00;
        network = ipHost & maskHost;
        broadcast = network | ~maskHost;
    }

    uint32_t gatewayHost = network + 1;
    if (gateway) *gateway = [self ipStringFromHostOrder:gatewayHost];

    int prefix = 0;
    uint32_t m = maskHost;
    while (m & 0x80000000) {
        prefix++;
        m <<= 1;
    }
    if (subnet) *subnet = [NSString stringWithFormat:@"%@/%d", [self ipStringFromHostOrder:network], prefix];

    for (uint32_t host = network + 1; host < broadcast; host++) {
        if (host == ipHost) {
            continue;
        }
        [hosts addObject:[self ipStringFromHostOrder:host]];
    }
    return hosts;
}

- (NSString *)ipStringFromHostOrder:(uint32_t)hostOrder {
    struct in_addr addr;
    addr.s_addr = htonl(hostOrder);
    char buffer[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &addr, buffer, sizeof(buffer));
    return [NSString stringWithUTF8String:buffer];
}

- (BOOL)ip:(NSString *)ip isInsideHosts:(NSArray<NSString *> *)hosts {
    return [hosts containsObject:ip];
}

- (NSInteger)lastOctet:(NSString *)ip {
    return [[ip componentsSeparatedByString:@"."].lastObject integerValue];
}

- (BOOL)probeHost:(NSString *)host timeout:(NSTimeInterval)timeout openPorts:(NSMutableArray<NSNumber *> *)openPorts {
    int ports[] = {80, 443, 22, 53, 62078};
    BOOL reachable = NO;
    for (NSUInteger i = 0; i < sizeof(ports) / sizeof(int); i++) {
        NSInteger state = [self probeStateForHost:host port:ports[i] timeout:timeout];
        if (state > 0) {
            reachable = YES;
            [openPorts addObject:@(ports[i])];
        } else if (state == 0) {
            reachable = YES;
        }
    }
    return reachable;
}

- (NSArray<NSNumber *> *)deepFingerprintPortsForHost:(NSString *)host timeout:(NSTimeInterval)timeout {
    int ports[] = {445, 548, 554, 631, 7000, 8008, 8009, 8060, 8080, 5000, 5001, 1883, 8123, 32400, 5900};
    NSMutableArray<NSNumber *> *openPorts = [NSMutableArray array];
    for (NSUInteger i = 0; i < sizeof(ports) / sizeof(int); i++) {
        if ([self probeStateForHost:host port:ports[i] timeout:timeout] > 0) {
            [openPorts addObject:@(ports[i])];
        }
    }
    return openPorts;
}

- (BOOL)probeHost:(NSString *)host port:(int)port timeout:(NSTimeInterval)timeout {
    return [self probeStateForHost:host port:port timeout:timeout] >= 0;
}

- (NSInteger)probeStateForHost:(NSString *)host port:(int)port timeout:(NSTimeInterval)timeout {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        return -1;
    }

    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) != 1) {
        close(sock);
        return -1;
    }

    int connectResult = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    if (connectResult == 0) {
        close(sock);
        return 1;
    }
    if (errno != EINPROGRESS) {
        NSInteger state = (errno == ECONNREFUSED) ? 0 : -1;
        close(sock);
        return state;
    }

    fd_set writeSet;
    FD_ZERO(&writeSet);
    FD_SET(sock, &writeSet);

    struct timeval tv;
    tv.tv_sec = (int)floor(timeout);
    tv.tv_usec = (int)((timeout - floor(timeout)) * 1000000.0);
    int selected = select(sock + 1, NULL, &writeSet, NULL, &tv);
    if (selected <= 0) {
        close(sock);
        return -1;
    }

    int error = 0;
    socklen_t len = sizeof(error);
    getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &len);
    close(sock);
    if (error == 0) {
        return 1;
    }
    return error == ECONNREFUSED ? 0 : -1;
}

- (NSDictionary<NSString *, NSString *> *)ssdpDiscoveryWithTimeout:(NSTimeInterval)timeout {
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        return responses;
    }

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(1900);
    inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr);

    const char *message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n";
    sendto(sock, message, strlen(message), 0, (struct sockaddr *)&addr, sizeof(addr));

    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:end] == NSOrderedAscending) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(sock, &readSet);

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 120000;
        int selected = select(sock + 1, &readSet, NULL, NULL, &tv);
        if (selected <= 0) {
            continue;
        }

        char buffer[2048];
        struct sockaddr_in from;
        socklen_t fromLen = sizeof(from);
        ssize_t count = recvfrom(sock, buffer, sizeof(buffer) - 1, 0, (struct sockaddr *)&from, &fromLen);
        if (count <= 0) {
            continue;
        }
        buffer[count] = '\0';
        char ipBuffer[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &from.sin_addr, ipBuffer, sizeof(ipBuffer));
        NSString *ip = [NSString stringWithUTF8String:ipBuffer];
        NSString *raw = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)count encoding:NSUTF8StringEncoding] ?: @"";
        NSString *existing = responses[ip] ?: @"";
        responses[ip] = [existing stringByAppendingString:[raw lowercaseString]];
    }

    close(sock);
    return responses;
}

- (NSDictionary<NSString *, NSString *> *)arpTable {
    NSMutableDictionary *table = [NSMutableDictionary dictionary];
    FILE *pipe = popen("/usr/sbin/arp -an 2>/dev/null", "r");
    if (!pipe) {
        pipe = popen("/usr/bin/arp -an 2>/dev/null", "r");
    }
    if (!pipe) {
        pipe = popen("/sbin/arp -an 2>/dev/null", "r");
    }
    if (!pipe) {
        return table;
    }

    char line[512];
    while (fgets(line, sizeof(line), pipe) != NULL) {
        NSString *raw = [NSString stringWithUTF8String:line];
        NSRange open = [raw rangeOfString:@"("];
        NSRange close = [raw rangeOfString:@")"];
        NSRange at = [raw rangeOfString:@" at "];
        NSRange on = [raw rangeOfString:@" on "];
        if (open.location == NSNotFound || close.location == NSNotFound || at.location == NSNotFound || on.location == NSNotFound) {
            continue;
        }
        if (close.location <= open.location || on.location <= at.location) {
            continue;
        }
        NSString *ip = [raw substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
        NSUInteger macStart = at.location + at.length;
        NSString *mac = [raw substringWithRange:NSMakeRange(macStart, on.location - macStart)];
        if ([mac containsString:@"incomplete"] || mac.length < 8) {
            continue;
        }
        table[ip] = [mac uppercaseString];
    }
    pclose(pipe);
    return table;
}

- (NSString *)displayNameForIP:(NSString *)ip vendor:(NSString *)vendor serviceHint:(NSString *)serviceHint gateway:(BOOL)gateway {
    if (gateway) {
        return @"Router";
    }

    NSString *friendly = [self friendlyNameFromServiceHint:serviceHint];
    if (friendly.length > 0) {
        return friendly;
    }

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    inet_pton(AF_INET, ip.UTF8String, &sa.sin_addr);

    char host[NI_MAXHOST];
    int result = getnameinfo((struct sockaddr *)&sa, sizeof(sa), host, sizeof(host), NULL, 0, NI_NAMEREQD);
    if (result == 0) {
        NSString *hostname = [NSString stringWithUTF8String:host];
        if (hostname.length > 0 && ![hostname isEqualToString:ip]) {
            return hostname;
        }
    }

    if (vendor.length > 0) {
        return vendor;
    }
    return [NSString stringWithFormat:@"Device %@", @([self lastOctet:ip])];
}

- (NSString *)friendlyNameFromServiceHint:(NSString *)serviceHint {
    NSString *hint = [serviceHint lowercaseString];
    if ([hint containsString:@"roku"]) return @"Roku";
    if ([hint containsString:@"chromecast"] || [hint containsString:@"google cast"]) return @"Chromecast";
    if ([hint containsString:@"sonos"]) return @"Sonos";
    if ([hint containsString:@"philips hue"]) return @"Hue";
    if ([hint containsString:@"belkin"] || [hint containsString:@"wemo"]) return @"Wemo";
    if ([hint containsString:@"ecobee"]) return @"Ecobee";
    if ([hint containsString:@"printer"]) return @"Printer";
    if ([hint containsString:@"plex"]) return @"Plex";
    if ([hint containsString:@"upnp:rootdevice"]) return @"UPnP Device";
    return @"";
}

- (NSString *)vendorForMAC:(NSString *)mac {
    if (mac.length < 8) {
        return @"";
    }
    NSString *prefix = [[mac substringToIndex:8] uppercaseString];
    NSDictionary *vendors = @{
        @"00:03:93": @"Apple", @"00:05:02": @"Apple", @"00:0A:27": @"Apple", @"00:0A:95": @"Apple",
        @"00:0D:93": @"Apple", @"00:11:24": @"Apple", @"00:14:51": @"Apple", @"00:16:CB": @"Apple",
        @"00:17:F2": @"Apple", @"00:19:E3": @"Apple", @"00:1B:63": @"Apple", @"00:1E:52": @"Apple",
        @"00:1F:5B": @"Apple", @"00:21:E9": @"Apple", @"00:22:41": @"Apple", @"00:23:12": @"Apple",
        @"00:23:32": @"Apple", @"00:23:6C": @"Apple", @"00:25:00": @"Apple", @"00:25:4B": @"Apple",
        @"00:26:08": @"Apple", @"00:26:4A": @"Apple", @"00:26:B0": @"Apple", @"04:0C:CE": @"Apple",
        @"04:DB:56": @"Apple", @"08:00:07": @"Apple", @"10:40:F3": @"Apple", @"14:10:9F": @"Apple",
        @"18:65:90": @"Apple", @"1C:1A:C0": @"Apple", @"20:C9:D0": @"Apple", @"24:A2:E1": @"Apple",
        @"28:CF:E9": @"Apple", @"2C:F0:A2": @"Apple", @"34:15:9E": @"Apple", @"38:C9:86": @"Apple",
        @"3C:07:54": @"Apple", @"40:A6:D9": @"Apple", @"44:00:10": @"Apple", @"48:A1:95": @"Apple",
        @"5C:95:AE": @"Apple", @"60:F8:1D": @"Apple", @"68:FE:F7": @"Apple", @"70:DE:E2": @"Apple",
        @"78:31:C1": @"Apple", @"7C:C3:A1": @"Apple", @"88:63:DF": @"Apple", @"8C:85:90": @"Apple",
        @"90:72:40": @"Apple", @"98:D6:BB": @"Apple", @"A4:5E:60": @"Apple", @"AC:BC:32": @"Apple",
        @"B8:17:C2": @"Apple", @"C8:2A:14": @"Apple", @"D0:03:4B": @"Apple", @"D8:30:62": @"Apple",
        @"E0:B9:BA": @"Apple", @"F0:18:98": @"Apple", @"F4:5C:89": @"Apple",
        @"B8:27:EB": @"Raspberry Pi", @"DC:A6:32": @"Raspberry Pi", @"E4:5F:01": @"Raspberry Pi",
        @"18:B4:30": @"Nest", @"64:16:66": @"Nest", @"D8:8C:79": @"Google", @"F4:F5:D8": @"Google",
        @"44:65:0D": @"Amazon", @"50:F5:DA": @"Amazon", @"68:54:FD": @"Amazon", @"74:C2:46": @"Amazon",
        @"84:D6:D0": @"Amazon", @"AC:63:BE": @"Amazon", @"FC:A6:67": @"Amazon",
        @"C8:3A:35": @"Roku", @"CC:6D:A0": @"Roku", @"D8:31:34": @"Roku",
        @"00:0C:E7": @"Media", @"00:13:A9": @"Sony", @"00:1A:11": @"Google",
        @"00:18:4D": @"Netgear", @"00:1B:2F": @"Netgear", @"20:4E:7F": @"Netgear",
        @"50:C7:BF": @"TP-Link", @"68:FF:7B": @"TP-Link", @"98:DE:D0": @"TP-Link",
        @"24:A4:3C": @"Ubiquiti", @"44:D9:E7": @"Ubiquiti", @"68:D7:9A": @"Ubiquiti",
        @"B4:FB:E4": @"Ubiquiti", @"F0:9F:C2": @"Ubiquiti", @"FC:EC:DA": @"Ubiquiti"
    };
    return vendors[prefix] ?: @"";
}

- (NSString *)typeForName:(NSString *)name vendor:(NSString *)vendor serviceHint:(NSString *)serviceHint openPorts:(NSArray<NSNumber *> *)openPorts gateway:(BOOL)gateway {
    if (gateway) {
        return @"Network";
    }
    NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@", name ?: @"", vendor ?: @"", serviceHint ?: @""] lowercaseString];
    NSSet<NSNumber *> *ports = [NSSet setWithArray:openPorts ?: @[]];

    if ([ports containsObject:@62078]) {
        return @"Phones";
    }
    if ([ports containsObject:@8060] || [ports containsObject:@8008] || [ports containsObject:@8009] || [ports containsObject:@7000] || [ports containsObject:@32400]) {
        return @"Media";
    }
    if ([ports containsObject:@548] || [ports containsObject:@445] || [ports containsObject:@5900]) {
        return @"Computers";
    }
    if ([ports containsObject:@8123] || [ports containsObject:@1883]) {
        return @"Smart Home";
    }

    if ([haystack containsString:@"iphone"] || [haystack containsString:@"ipad"] || [haystack containsString:@"android"] || [haystack containsString:@"phone"]) {
        return @"Phones";
    }
    if ([haystack containsString:@"macbook"] || [haystack containsString:@"imac"] || [haystack containsString:@"windows"] || [haystack containsString:@"laptop"] || [haystack containsString:@"desktop"]) {
        return @"Computers";
    }
    if ([haystack containsString:@"roku"] || [haystack containsString:@"tv"] || [haystack containsString:@"playstation"] || [haystack containsString:@"xbox"] || [haystack containsString:@"media"] || [haystack containsString:@"chromecast"] || [haystack containsString:@"plex"] || [haystack containsString:@"sonos"] || [haystack containsString:@"dlna"]) {
        return @"Media";
    }
    if ([haystack containsString:@"nest"] || [haystack containsString:@"amazon"] || [haystack containsString:@"echo"] || [haystack containsString:@"esp"] || [haystack containsString:@"raspberry"] || [haystack containsString:@"google"] || [haystack containsString:@"hue"] || [haystack containsString:@"wemo"] || [haystack containsString:@"ecobee"] || [haystack containsString:@"smart"]) {
        return @"Smart Home";
    }
    if ([haystack containsString:@"ubiquiti"] || [haystack containsString:@"netgear"] || [haystack containsString:@"router"] || [haystack containsString:@"tp-link"] || [haystack containsString:@"arris"] || [haystack containsString:@"gateway"] || [haystack containsString:@"access point"]) {
        return @"Network";
    }
    if ([vendor isEqualToString:@"Apple"]) {
        return @"Phones";
    }
    return @"Unknown";
}

- (NSString *)normalizedType:(NSString *)type {
    NSString *value = [[type ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0) return @"";
    if ([value containsString:@"phone"] || [value containsString:@"tablet"] || [value containsString:@"mobile"]) return @"Phones";
    if ([value containsString:@"computer"] || [value containsString:@"laptop"] || [value containsString:@"desktop"] || [value containsString:@"server"]) return @"Computers";
    if ([value containsString:@"smart"] || [value containsString:@"iot"] || [value containsString:@"home"] || [value containsString:@"sensor"]) return @"Smart Home";
    if ([value containsString:@"media"] || [value containsString:@"tv"] || [value containsString:@"speaker"] || [value containsString:@"cast"]) return @"Media";
    if ([value containsString:@"router"] || [value containsString:@"network"] || [value containsString:@"gateway"] || [value containsString:@"ap"]) return @"Network";
    if ([value containsString:@"unknown"]) return @"Unknown";
    return type;
}

- (NSInteger)confidenceForDevice:(NWDevice *)device gateway:(BOOL)gateway {
    if (gateway) return 95;
    if ([device.source isEqualToString:@"collector"]) return 95;
    NSInteger confidence = 10;
    if (device.mac.length > 0 && device.vendor.length > 0) confidence = MAX(confidence, 60);
    if (device.serviceHint.length > 0) confidence = MAX(confidence, 70);
    if (device.openPorts.count > 0) confidence = MAX(confidence, 55);
    if (device.serviceHint.length > 0 && device.openPorts.count > 0) confidence = MAX(confidence, 78);
    if (![device.type isEqualToString:@"Unknown"] && device.vendor.length > 0) confidence = MAX(confidence, 72);
    if (![device.type isEqualToString:@"Unknown"] && device.serviceHint.length > 0) confidence = MAX(confidence, 82);
    return confidence;
}

- (NSString *)sourceForDevice:(NWDevice *)device {
    if (device.serviceHint.length > 0 && device.openPorts.count > 0) return @"service";
    if (device.serviceHint.length > 0) return @"bonjour";
    if (device.mac.length > 0) return @"arp";
    if (device.openPorts.count > 0) return @"ports";
    return @"probe";
}

@end

@interface DashboardViewController ()

@property (nonatomic, strong) NWNetworkScanner *scanner;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, strong) NWScanResult *lastResult;
@property (nonatomic, strong) NSArray<NSDictionary *> *historySamples;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic) BOOL scanning;
@property (nonatomic) NWTab selectedTab;
@property (nonatomic) NSTimeInterval refreshInterval;

@property (nonatomic, strong) UIStackView *rootStack;
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *freshnessLabel;
@property (nonatomic, strong) UIView *contentView;

@end

@implementation DashboardViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _scanner = [[NWNetworkScanner alloc] init];
        _selectedTab = NWTabDashboard;
        _events = [NSMutableArray array];
        _refreshInterval = [[NSUserDefaults standardUserDefaults] doubleForKey:NWRefreshIntervalKey];
        if (_refreshInterval < 15.0) {
            _refreshInterval = NWDefaultRefreshInterval;
        }
        _historySamples = [[NSUserDefaults standardUserDefaults] arrayForKey:NWHistoricalSamplesKey] ?: @[];
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [self colorBackground];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self buildInterface];
    [self render];
    [self startTimers];
    [self startScan];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.clockTimer invalidate];
    [self.scanTimer invalidate];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)buildInterface {
    self.rootStack = [[UIStackView alloc] init];
    self.rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rootStack.axis = UILayoutConstraintAxisVertical;
    self.rootStack.spacing = 8.0;
    self.rootStack.layoutMargins = UIEdgeInsetsMake(9, 12, 10, 12);
    self.rootStack.layoutMarginsRelativeArrangement = YES;
    [self.view addSubview:self.rootStack];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.rootStack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.rootStack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.rootStack.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.rootStack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]
    ]];

    [self.rootStack addArrangedSubview:[self headerView]];

    self.contentView = [[UIView alloc] init];
    [self.rootStack addArrangedSubview:self.contentView];
}

- (UIView *)headerView {
    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12.0;
    [header.heightAnchor constraintEqualToConstant:30.0].active = YES;

    UILabel *title = [self labelWithSize:15 weight:UIFontWeightBlack color:[self colorAccent]];
    title.text = @"NET WALL";
    [title setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"Now", @"Devices", @"History", @"Settings"]];
    self.tabs.selectedSegmentIndex = self.selectedTab;
    self.tabs.tintColor = [self colorAccent];
    [self.tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.tabs.widthAnchor constraintEqualToConstant:292.0].active = YES;
    [self.tabs.heightAnchor constraintEqualToConstant:28.0].active = YES;

    self.freshnessLabel = [self labelWithSize:11 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.56 alpha:1.0]];
    self.freshnessLabel.textAlignment = NSTextAlignmentRight;
    self.timeLabel = [self labelWithSize:22 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.90 alpha:1.0]];
    self.timeLabel.textAlignment = NSTextAlignmentRight;
    [self.timeLabel.widthAnchor constraintEqualToConstant:84.0].active = YES;

    UIView *spacer = [[UIView alloc] init];
    [header addArrangedSubview:title];
    [header addArrangedSubview:self.tabs];
    [header addArrangedSubview:spacer];
    [header addArrangedSubview:self.freshnessLabel];
    [header addArrangedSubview:self.timeLabel];
    return header;
}

- (void)startTimers {
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self resetScanTimer];
    [self tick];
}

- (void)resetScanTimer {
    [self.scanTimer invalidate];
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:self.refreshInterval target:self selector:@selector(startScan) userInfo:nil repeats:YES];
}

- (void)tick {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"h:mm";
    self.timeLabel.text = [formatter stringFromDate:[NSDate date]];

    if (self.scanning) {
        self.freshnessLabel.text = @"scanning...";
    } else if (self.lastResult.scanDate) {
        NSInteger seconds = (NSInteger)round([[NSDate date] timeIntervalSinceDate:self.lastResult.scanDate]);
        self.freshnessLabel.text = [NSString stringWithFormat:@"scanned %lds ago", (long)seconds];
    } else {
        self.freshnessLabel.text = @"waiting";
    }
}

- (void)tabChanged:(UISegmentedControl *)sender {
    self.selectedTab = (NWTab)sender.selectedSegmentIndex;
    [self render];
}

- (void)startScan {
    if (self.scanning) {
        return;
    }
    self.scanning = YES;
    [self tick];

    __weak typeof(self) weakSelf = self;
    [self.scanner scanWithCompletion:^(NWScanResult *result) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.scanning = NO;
        [strongSelf consumeScanResult:result];
        [strongSelf tick];
        [strongSelf render];
    }];
}

- (void)consumeScanResult:(NWScanResult *)result {
    NSInteger previousCount = self.lastResult.devices.count;
    self.lastResult = result;

    NSInteger newCount = [self countNewDevices:result.devices];
    if (newCount > 0) {
        [self addEvent:[NSString stringWithFormat:@"%ld new device%@ joined", (long)newCount, newCount == 1 ? @"" : @"s"]];
    } else if (previousCount > 0 && result.devices.count < previousCount) {
        [self addEvent:[NSString stringWithFormat:@"%ld device%@ left", (long)(previousCount - result.devices.count), previousCount - result.devices.count == 1 ? @"" : @"s"]];
    } else {
        [self addEvent:@"Scan complete"];
    }

    NSMutableArray *samples = [self.historySamples mutableCopy];
    [samples addObject:@{@"time": @([result.scanDate timeIntervalSince1970]), @"count": @(result.devices.count), @"unknown": @([self countForType:@"Unknown" devices:result.devices])}];
    while (samples.count > 96) {
        [samples removeObjectAtIndex:0];
    }
    self.historySamples = samples;
    [[NSUserDefaults standardUserDefaults] setObject:self.historySamples forKey:NWHistoricalSamplesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)addEvent:(NSString *)event {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"h:mm";
    NSString *line = [NSString stringWithFormat:@"%@  %@", [formatter stringFromDate:[NSDate date]], event];
    [self.events insertObject:line atIndex:0];
    while (self.events.count > 6) {
        [self.events removeLastObject];
    }
}

- (void)render {
    for (UIView *subview in self.contentView.subviews) {
        [subview removeFromSuperview];
    }

    UIView *view = nil;
    if (self.selectedTab == NWTabDashboard) {
        view = [self dashboardView];
    } else if (self.selectedTab == NWTabDevices) {
        view = [self deviceListView];
    } else if (self.selectedTab == NWTabHistory) {
        view = [self historyView];
    } else {
        view = [self settingsView];
    }

    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor]
    ]];
}

- (UIView *)dashboardView {
    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 7.0;

    UIStackView *top = [[UIStackView alloc] init];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.spacing = 8.0;
    top.distribution = UIStackViewDistributionFill;
    [root addArrangedSubview:top];
    [top.heightAnchor constraintEqualToAnchor:root.heightAnchor multiplier:0.50].active = YES;

    [top addArrangedSubview:[self countPanel]];
    UIView *health = [self healthGrid];
    [top addArrangedSubview:health];
    [health.widthAnchor constraintEqualToAnchor:top.widthAnchor multiplier:0.43].active = YES;

    [root addArrangedSubview:[self typeSummaryView]];
    [root addArrangedSubview:[self eventStripView]];
    return root;
}

- (UIView *)countPanel {
    UIView *panel = [self panelView];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 0.0;
    stack.layoutMargins = UIEdgeInsetsMake(10, 14, 10, 14);
    stack.layoutMarginsRelativeArrangement = YES;
    [panel addSubview:stack];

    UILabel *value = [self labelWithSize:86 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    value.text = [NSString stringWithFormat:@"%ld", (long)self.lastResult.devices.count];
    value.minimumScaleFactor = 0.5;
    value.adjustsFontSizeToFitWidth = YES;

    UILabel *title = [self labelWithSize:18 weight:UIFontWeightBold color:[UIColor colorWithWhite:0.82 alpha:1.0]];
    title.text = @"Devices Online";

    NSInteger unknown = [self countForType:@"Unknown" devices:self.lastResult.devices];
    UILabel *detail = [self labelWithSize:14 weight:UIFontWeightSemibold color:unknown > 0 ? [self colorWarn] : [self colorMuted]];
    if (!self.lastResult) {
        detail.text = self.scanning ? @"scanning local network" : @"ready to scan";
    } else {
        NSInteger classified = self.lastResult.devices.count - unknown;
        detail.text = [NSString stringWithFormat:@"%@ classified  /  %@ unknown", @(classified), @(unknown)];
    }

    [stack addArrangedSubview:value];
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor]
    ]];
    return panel;
}

- (UIView *)healthGrid {
    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 7.0;
    grid.distribution = UIStackViewDistributionFillEqually;

    UIStackView *row1 = [[UIStackView alloc] init];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.spacing = 7.0;
    row1.distribution = UIStackViewDistributionFillEqually;

    UIStackView *row2 = [[UIStackView alloc] init];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.spacing = 7.0;
    row2.distribution = UIStackViewDistributionFillEqually;

    NWMetricTile *gateway = [[NWMetricTile alloc] initWithTitle:@"Gateway" color:[self statusColor:self.lastResult.gatewayOK]];
    [gateway updateValue:self.lastResult.gatewayOK ? @"OK" : @"--" subtitle:self.lastResult.gateway.length ? self.lastResult.gateway : @"router" color:[self statusColor:self.lastResult.gatewayOK]];

    NWMetricTile *dns = [[NWMetricTile alloc] initWithTitle:@"DNS" color:[self statusColor:self.lastResult.dnsOK]];
    [dns updateValue:self.lastResult.dnsOK ? @"OK" : @"--" subtitle:@"resolver" color:[self statusColor:self.lastResult.dnsOK]];

    NWMetricTile *internet = [[NWMetricTile alloc] initWithTitle:@"Internet" color:[self statusColor:self.lastResult.internetOK]];
    [internet updateValue:self.lastResult.internetOK ? @"OK" : @"--" subtitle:@"WAN check" color:[self statusColor:self.lastResult.internetOK]];

    NWMetricTile *latency = [[NWMetricTile alloc] initWithTitle:@"Latency" color:[self colorAccent]];
    NSString *latencyValue = self.lastResult.gatewayLatencyMs >= 0 ? [NSString stringWithFormat:@"%@ ms", @(self.lastResult.gatewayLatencyMs)] : @"--";
    if (self.lastResult.gatewayLatencyMs < 0 && self.lastResult.gatewayOK) {
        latencyValue = @"LAN";
    }
    [latency updateValue:latencyValue subtitle:self.lastResult.subnet ?: @"local" color:self.lastResult.gatewayLatencyMs >= 0 ? [self colorAccent] : (self.lastResult.gatewayOK ? [self colorGood] : [self colorMuted])];

    [row1 addArrangedSubview:gateway];
    [row1 addArrangedSubview:dns];
    [row2 addArrangedSubview:internet];
    [row2 addArrangedSubview:latency];
    [grid addArrangedSubview:row1];
    [grid addArrangedSubview:row2];
    return grid;
}

- (UIView *)typeSummaryView {
    UIView *panel = [self panelView];
    [panel.heightAnchor constraintEqualToConstant:92.0].active = YES;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 6.0;
    stack.layoutMargins = UIEdgeInsetsMake(9, 10, 9, 10);
    stack.layoutMarginsRelativeArrangement = YES;
    [panel addSubview:stack];

    NSArray *types = @[@"Phones", @"Computers", @"Smart Home", @"Media", @"Network", @"Unknown"];
    for (NSString *type in types) {
        [stack addArrangedSubview:[self typeTile:type count:[self countForType:type devices:self.lastResult.devices]]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor]
    ]];
    return panel;
}

- (UIView *)typeTile:(NSString *)type count:(NSInteger)count {
    UIView *tile = [[UIView alloc] init];
    tile.backgroundColor = [UIColor colorWithRed:0.118 green:0.130 blue:0.140 alpha:1.0];
    tile.layer.cornerRadius = 7.0;
    tile.clipsToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 3.0;
    stack.layoutMargins = UIEdgeInsetsMake(6, 8, 6, 8);
    stack.layoutMarginsRelativeArrangement = YES;
    [tile addSubview:stack];

    UILabel *typeLabel = [self labelWithSize:9 weight:UIFontWeightBlack color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    typeLabel.text = [type uppercaseString];
    typeLabel.minimumScaleFactor = 0.56;
    typeLabel.adjustsFontSizeToFitWidth = YES;

    UIColor *countColor = count == 0 ? [UIColor colorWithWhite:0.36 alpha:1.0] : [UIColor whiteColor];
    if ([type isEqualToString:@"Unknown"] && count > 0) {
        countColor = [self colorWarn];
    } else if ([type isEqualToString:@"Network"] && count > 0) {
        countColor = [self colorAccent];
    }
    UILabel *countLabel = [self labelWithSize:27 weight:UIFontWeightBlack color:countColor];
    countLabel.text = [NSString stringWithFormat:@"%ld", (long)count];

    [stack addArrangedSubview:typeLabel];
    [stack addArrangedSubview:countLabel];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:tile.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor]
    ]];
    return tile;
}

- (UIView *)eventStripView {
    UIView *panel = [self panelView];
    [panel.heightAnchor constraintEqualToConstant:30.0].active = YES;
    UILabel *label = [self labelWithSize:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.76 alpha:1.0]];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = self.events.firstObject ?: @"No events yet";
    [panel addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [label.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor]
    ]];
    return panel;
}

- (UIView *)deviceListView {
    UIView *panel = [self panelView];

    UIStackView *root = [[UIStackView alloc] init];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 7.0;
    root.layoutMargins = UIEdgeInsetsMake(8, 10, 8, 10);
    root.layoutMarginsRelativeArrangement = YES;
    [panel addSubview:root];

    UIStackView *summary = [[UIStackView alloc] init];
    summary.axis = UILayoutConstraintAxisHorizontal;
    summary.alignment = UIStackViewAlignmentCenter;
    summary.distribution = UIStackViewDistributionEqualSpacing;

    UILabel *title = [self labelWithSize:17 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    title.text = [NSString stringWithFormat:@"%ld Devices", (long)self.lastResult.devices.count];

    NSInteger unknown = [self countForType:@"Unknown" devices:self.lastResult.devices];
    UILabel *detail = [self labelWithSize:13 weight:UIFontWeightBold color:unknown > 0 ? [self colorWarn] : [self colorGood]];
    detail.text = self.scanning ? @"scanning..." : [NSString stringWithFormat:@"%@ unknown", @(unknown)];
    detail.textAlignment = NSTextAlignmentRight;

    [summary addArrangedSubview:title];
    [summary addArrangedSubview:detail];
    [root addArrangedSubview:summary];
    [summary.heightAnchor constraintEqualToConstant:24.0].active = YES;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [root addArrangedSubview:scroll];

    UIStackView *rows = [[UIStackView alloc] init];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 6.0;
    [scroll addSubview:rows];

    NSArray<NWDevice *> *devices = [self sortedDevicesForList];
    if (devices.count == 0) {
        UILabel *empty = [self labelWithSize:18 weight:UIFontWeightBold color:[self colorMuted]];
        empty.text = self.scanning ? @"Scanning local network..." : @"No devices found yet";
        empty.textAlignment = NSTextAlignmentCenter;
        [rows addArrangedSubview:empty];
        [empty.heightAnchor constraintEqualToConstant:170.0].active = YES;
    } else {
        for (NWDevice *device in devices) {
            [rows addArrangedSubview:[self deviceRowView:device]];
        }
    }

    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],

        [rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];

    return panel;
}

- (NSArray<NWDevice *> *)sortedDevicesForList {
    NSArray *priority = @[@"Unknown", @"Network", @"Phones", @"Computers", @"Smart Home", @"Media"];
    return [self.lastResult.devices sortedArrayUsingComparator:^NSComparisonResult(NWDevice *a, NWDevice *b) {
        NSInteger aPriority = [priority containsObject:a.type] ? [priority indexOfObject:a.type] : 99;
        NSInteger bPriority = [priority containsObject:b.type] ? [priority indexOfObject:b.type] : 99;
        if (aPriority != bPriority) {
            return [@(aPriority) compare:@(bPriority)];
        }
        return [@([self lastOctetForIP:a.ip]) compare:@([self lastOctetForIP:b.ip])];
    }];
}

- (UIView *)deviceRowView:(NWDevice *)device {
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor colorWithRed:0.112 green:0.124 blue:0.134 alpha:1.0];
    row.layer.cornerRadius = 7.0;
    row.clipsToBounds = YES;
    [row.heightAnchor constraintEqualToConstant:48.0].active = YES;

    UIView *stripe = [[UIView alloc] init];
    stripe.translatesAutoresizingMaskIntoConstraints = NO;
    stripe.backgroundColor = [self colorForDeviceType:device.type];
    [row addSubview:stripe];

    UIStackView *content = [[UIStackView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 10.0;
    [row addSubview:content];

    UIStackView *nameStack = [[UIStackView alloc] init];
    nameStack.axis = UILayoutConstraintAxisVertical;
    nameStack.spacing = 1.0;

    UILabel *name = [self labelWithSize:15 weight:UIFontWeightBlack color:[UIColor colorWithWhite:0.92 alpha:1.0]];
    name.text = device.name.length ? device.name : @"Device";
    name.minimumScaleFactor = 0.68;
    name.adjustsFontSizeToFitWidth = YES;

    UILabel *meta = [self labelWithSize:10 weight:UIFontWeightBold color:[UIColor colorWithWhite:0.54 alpha:1.0]];
    NSString *vendor = device.vendor.length ? device.vendor : device.type;
    meta.text = [NSString stringWithFormat:@"%@  %@", device.type ?: @"Unknown", vendor ?: @""];
    meta.minimumScaleFactor = 0.7;
    meta.adjustsFontSizeToFitWidth = YES;

    [nameStack addArrangedSubview:name];
    [nameStack addArrangedSubview:meta];
    [content addArrangedSubview:nameStack];

    UIStackView *detailStack = [[UIStackView alloc] init];
    detailStack.axis = UILayoutConstraintAxisVertical;
    detailStack.alignment = UIStackViewAlignmentTrailing;
    detailStack.spacing = 1.0;
    [detailStack.widthAnchor constraintEqualToConstant:170.0].active = YES;

    UILabel *ip = [self labelWithSize:14 weight:UIFontWeightBlack color:[UIColor whiteColor]];
    ip.text = device.ip ?: @"";
    ip.textAlignment = NSTextAlignmentRight;

    UILabel *hint = [self labelWithSize:10 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    hint.text = [self deviceHintText:device];
    hint.textAlignment = NSTextAlignmentRight;
    hint.minimumScaleFactor = 0.62;
    hint.adjustsFontSizeToFitWidth = YES;

    [detailStack addArrangedSubview:ip];
    [detailStack addArrangedSubview:hint];
    [content addArrangedSubview:detailStack];

    [NSLayoutConstraint activateConstraints:@[
        [stripe.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [stripe.topAnchor constraintEqualToAnchor:row.topAnchor],
        [stripe.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [stripe.widthAnchor constraintEqualToConstant:5.0],

        [content.leadingAnchor constraintEqualToAnchor:stripe.trailingAnchor constant:10.0],
        [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10.0],
        [content.topAnchor constraintEqualToAnchor:row.topAnchor constant:5.0],
        [content.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-5.0]
    ]];

    return row;
}

- (NSString *)deviceHintText:(NWDevice *)device {
    if (device.openPorts.count > 0) {
        NSMutableArray *ports = [NSMutableArray array];
        NSUInteger limit = MIN((NSUInteger)4, device.openPorts.count);
        for (NSUInteger i = 0; i < limit; i++) {
            [ports addObject:[device.openPorts[i] stringValue]];
        }
        NSString *suffix = device.openPorts.count > limit ? @"+" : @"";
        return [NSString stringWithFormat:@"ports %@%@", [ports componentsJoinedByString:@","], suffix];
    }
    if (device.mac.length > 0) {
        return device.mac;
    }
    if (device.serviceHint.length > 0) {
        return @"SSDP";
    }
    return device.isNew ? @"new" : @"seen";
}

- (UIColor *)colorForDeviceType:(NSString *)type {
    if ([type isEqualToString:@"Unknown"]) return [self colorWarn];
    if ([type isEqualToString:@"Network"]) return [self colorAccent];
    if ([type isEqualToString:@"Phones"]) return [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
    if ([type isEqualToString:@"Computers"]) return [UIColor colorWithRed:0.67 green:0.72 blue:1.0 alpha:1.0];
    if ([type isEqualToString:@"Smart Home"]) return [self colorGood];
    if ([type isEqualToString:@"Media"]) return [UIColor colorWithRed:1.0 green:0.48 blue:0.38 alpha:1.0];
    return [self colorMuted];
}

- (NSInteger)lastOctetForIP:(NSString *)ip {
    return [[ip componentsSeparatedByString:@"."].lastObject integerValue];
}

- (UIView *)historyView {
    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 7.0;

    NWHistoryChartView *chart = [[NWHistoryChartView alloc] init];
    chart.samples = self.historySamples;
    [root addArrangedSubview:chart];
    [chart.heightAnchor constraintEqualToAnchor:root.heightAnchor multiplier:0.55].active = YES;

    UIStackView *summary = [[UIStackView alloc] init];
    summary.axis = UILayoutConstraintAxisHorizontal;
    summary.spacing = 7.0;
    summary.distribution = UIStackViewDistributionFillEqually;

    NSInteger peak = [self peakCount];
    NSInteger newCount = [self countNewDevices:self.lastResult.devices];
    NSInteger unknown = [self countForType:@"Unknown" devices:self.lastResult.devices];

    NWMetricTile *now = [[NWMetricTile alloc] initWithTitle:@"Now" color:[UIColor whiteColor]];
    [now updateValue:[NSString stringWithFormat:@"%ld", (long)self.lastResult.devices.count] subtitle:@"online" color:[UIColor whiteColor]];
    NWMetricTile *peakTile = [[NWMetricTile alloc] initWithTitle:@"Peak" color:[self colorAccent]];
    [peakTile updateValue:[NSString stringWithFormat:@"%ld", (long)peak] subtitle:@"saved scans" color:[self colorAccent]];
    NWMetricTile *newTile = [[NWMetricTile alloc] initWithTitle:@"New" color:newCount > 0 ? [self colorWarn] : [self colorGood]];
    [newTile updateValue:[NSString stringWithFormat:@"%ld", (long)newCount] subtitle:@"this scan" color:newCount > 0 ? [self colorWarn] : [self colorGood]];
    NWMetricTile *unknownTile = [[NWMetricTile alloc] initWithTitle:@"Unknown" color:unknown > 0 ? [self colorWarn] : [self colorGood]];
    [unknownTile updateValue:[NSString stringWithFormat:@"%ld", (long)unknown] subtitle:@"needs label" color:unknown > 0 ? [self colorWarn] : [self colorGood]];

    [summary addArrangedSubview:now];
    [summary addArrangedSubview:peakTile];
    [summary addArrangedSubview:newTile];
    [summary addArrangedSubview:unknownTile];
    [root addArrangedSubview:summary];
    [summary.heightAnchor constraintEqualToConstant:72.0].active = YES;

    [root addArrangedSubview:[self eventListView]];
    return root;
}

- (UIView *)eventListView {
    UIView *panel = [self panelView];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 3.0;
    stack.layoutMargins = UIEdgeInsetsMake(7, 12, 7, 12);
    stack.layoutMarginsRelativeArrangement = YES;
    [panel addSubview:stack];

    NSInteger rows = MIN(3, (NSInteger)self.events.count);
    if (rows == 0) {
        UILabel *empty = [self labelWithSize:14 weight:UIFontWeightSemibold color:[self colorMuted]];
        empty.text = @"No history events yet";
        [stack addArrangedSubview:empty];
    } else {
        for (NSInteger i = 0; i < rows; i++) {
            UILabel *row = [self labelWithSize:14 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.80 alpha:1.0]];
            row.text = self.events[i];
            [stack addArrangedSubview:row];
        }
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor]
    ]];
    return panel;
}

- (UIView *)settingsView {
    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 7.0;

    [root addArrangedSubview:[self settingsSection:@"Scanning" rows:@[
        [self settingsRow:@"Auto Refresh" value:@"On"],
        [self settingsRow:@"Refresh Every" value:[NSString stringWithFormat:@"%@ sec", @((NSInteger)self.refreshInterval)]],
        [self settingsRow:@"Subnet" value:self.lastResult.subnet ?: @"Detecting"],
        [self settingsRow:@"Gateway" value:self.lastResult.gateway.length ? self.lastResult.gateway : @"Detecting"]
    ]]];

    [root addArrangedSubview:[self settingsSection:@"Discovery" rows:@[
        [self settingsRow:@"TCP Sweep" value:@"Lightweight"],
        [self settingsRow:@"Bonjour / mDNS" value:@"On"],
        [self settingsRow:@"SSDP Discovery" value:@"On"],
        [self settingsRow:@"Deep Fingerprints" value:@"Unknown only"],
        [self settingsRow:@"Collector JSON" value:self.lastResult.collectorCount > 0 ? @"Connected" : @"Auto"],
        [self settingsRow:@"ARP Cache" value:@"On"],
        [self settingsRow:@"Router API" value:@"Off"]
    ]]];

    [root addArrangedSubview:[self settingsSection:@"Status" rows:@[
        [self settingsRow:@"Last Scan" value:self.lastResult.scanDate ? self.freshnessLabel.text : @"Never"],
        [self settingsRow:@"Devices Online" value:[NSString stringWithFormat:@"%ld", (long)self.lastResult.devices.count]],
        [self settingsRow:@"Unknown" value:[NSString stringWithFormat:@"%ld", (long)[self countForType:@"Unknown" devices:self.lastResult.devices]]]
    ]]];

    UIButton *scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    scanButton.backgroundColor = [self colorAccent];
    scanButton.layer.cornerRadius = 8.0;
    scanButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBlack];
    [scanButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [scanButton setTitle:self.scanning ? @"Scanning..." : @"Scan Now" forState:UIControlStateNormal];
    [scanButton addTarget:self action:@selector(startScan) forControlEvents:UIControlEventTouchUpInside];
    [scanButton.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [root addArrangedSubview:scanButton];

    return root;
}

- (UIView *)settingsSection:(NSString *)title rows:(NSArray<UIView *> *)rows {
    UIView *panel = [self panelView];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 1.0;
    stack.layoutMargins = UIEdgeInsetsMake(7, 12, 7, 12);
    stack.layoutMarginsRelativeArrangement = YES;
    [panel addSubview:stack];

    UILabel *titleLabel = [self labelWithSize:11 weight:UIFontWeightBlack color:[self colorAccent]];
    titleLabel.text = [title uppercaseString];
    [stack addArrangedSubview:titleLabel];

    for (UIView *row in rows) {
        [stack addArrangedSubview:row];
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor]
    ]];
    return panel;
}

- (UIView *)settingsRow:(NSString *)name value:(NSString *)value {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionEqualSpacing;
    [row.heightAnchor constraintEqualToConstant:23.0].active = YES;

    UILabel *nameLabel = [self labelWithSize:14 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.82 alpha:1.0]];
    nameLabel.text = name;
    UILabel *valueLabel = [self labelWithSize:14 weight:UIFontWeightBold color:[UIColor colorWithWhite:0.58 alpha:1.0]];
    valueLabel.text = value;
    valueLabel.textAlignment = NSTextAlignmentRight;

    [row addArrangedSubview:nameLabel];
    [row addArrangedSubview:valueLabel];
    return row;
}

- (NSInteger)countForType:(NSString *)type devices:(NSArray<NWDevice *> *)devices {
    NSInteger count = 0;
    for (NWDevice *device in devices) {
        if ([device.type isEqualToString:type]) {
            count++;
        }
    }
    return count;
}

- (NSInteger)countNewDevices:(NSArray<NWDevice *> *)devices {
    NSInteger count = 0;
    for (NWDevice *device in devices) {
        if (device.isNew) {
            count++;
        }
    }
    return count;
}

- (NSInteger)peakCount {
    NSInteger peak = self.lastResult.devices.count;
    for (NSDictionary *sample in self.historySamples) {
        peak = MAX(peak, [sample[@"count"] integerValue]);
    }
    return peak;
}

- (UIView *)panelView {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [self colorPanel];
    view.layer.cornerRadius = 8.0;
    view.clipsToBounds = YES;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.035].CGColor;
    return view;
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (UIColor *)colorBackground {
    return [UIColor colorWithRed:0.025 green:0.031 blue:0.036 alpha:1.0];
}

- (UIColor *)colorPanel {
    return [UIColor colorWithRed:0.078 green:0.088 blue:0.098 alpha:1.0];
}

- (UIColor *)colorAccent {
    return [UIColor colorWithRed:0.16 green:0.78 blue:0.88 alpha:1.0];
}

- (UIColor *)colorGood {
    return [UIColor colorWithRed:0.28 green:0.86 blue:0.48 alpha:1.0];
}

- (UIColor *)colorWarn {
    return [UIColor colorWithRed:1.0 green:0.72 blue:0.24 alpha:1.0];
}

- (UIColor *)colorBad {
    return [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
}

- (UIColor *)colorMuted {
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}

- (UIColor *)statusColor:(BOOL)ok {
    if (!self.lastResult) {
        return [self colorMuted];
    }
    return ok ? [self colorGood] : [self colorBad];
}

@end
