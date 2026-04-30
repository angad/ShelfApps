#import <Foundation/Foundation.h>

@class CMWebSocket;

@protocol CMWebSocketDelegate <NSObject>

- (void)webSocketDidOpen:(CMWebSocket *)webSocket;
- (void)webSocket:(CMWebSocket *)webSocket didReceiveText:(NSString *)text;
- (void)webSocket:(CMWebSocket *)webSocket didCloseWithError:(NSError *)error;

@end

@interface CMWebSocket : NSObject

@property (nonatomic, weak) id<CMWebSocketDelegate> delegate;

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers;
- (void)connect;
- (void)sendText:(NSString *)text;
- (void)close;

@end
