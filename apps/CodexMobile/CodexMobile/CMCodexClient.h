#import <Foundation/Foundation.h>
#import "CMWebSocket.h"

@class CMCodexClient;

@protocol CMCodexClientDelegate <NSObject>

- (void)codexClient:(CMCodexClient *)client didUpdateStatus:(NSString *)status connected:(BOOL)connected;
- (void)codexClient:(CMCodexClient *)client didAppendTranscript:(NSString *)text;
- (void)codexClient:(CMCodexClient *)client didUpdateFiles:(NSArray<NSDictionary *> *)files path:(NSString *)path;
- (void)codexClient:(CMCodexClient *)client didAppendTerminal:(NSString *)text;

@end

@interface CMCodexClient : NSObject <CMWebSocketDelegate>

@property (nonatomic, weak) id<CMCodexClientDelegate> delegate;
@property (nonatomic, copy, readonly) NSString *threadId;
@property (nonatomic, copy, readonly) NSString *cwd;

- (void)connectToURLString:(NSString *)urlString token:(NSString *)token cwd:(NSString *)cwd;
- (void)disconnect;
- (void)sendPrompt:(NSString *)prompt;
- (void)readDirectory:(NSString *)path;
- (void)runCommand:(NSString *)command;

@end
