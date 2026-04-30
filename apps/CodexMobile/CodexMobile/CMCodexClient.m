#import "CMCodexClient.h"

@interface CMCodexClient ()

@property (nonatomic, strong) CMWebSocket *socket;
@property (nonatomic) NSInteger nextId;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pending;
@property (nonatomic, copy, readwrite) NSString *threadId;
@property (nonatomic, copy, readwrite) NSString *cwd;

@end

@implementation CMCodexClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _nextId = 1;
        _pending = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)connectToURLString:(NSString *)urlString token:(NSString *)token cwd:(NSString *)cwd {
    [self disconnect];
    self.cwd = cwd.length ? cwd : @"/";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !([url.scheme.lowercaseString isEqualToString:@"ws"] || [url.scheme.lowercaseString isEqualToString:@"wss"])) {
        [self.delegate codexClient:self didUpdateStatus:@"Bad ws:// URL" connected:NO];
        return;
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSString *trimmedToken = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedToken.length) headers[@"Authorization"] = [@"Bearer " stringByAppendingString:trimmedToken];

    self.socket = [[CMWebSocket alloc] initWithURL:url headers:headers];
    self.socket.delegate = self;
    [self.delegate codexClient:self didUpdateStatus:@"Connecting" connected:NO];
    [self.socket connect];
}

- (void)disconnect {
    self.socket.delegate = nil;
    [self.socket close];
    self.socket = nil;
    self.threadId = nil;
}

- (void)sendPrompt:(NSString *)prompt {
    NSString *clean = [prompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!self.threadId.length || !clean.length) return;
    NSDictionary *params = @{
        @"threadId": self.threadId,
        @"input": @[ @{ @"type": @"text", @"text": clean, @"textElements": @[] } ],
        @"cwd": self.cwd ?: @"/",
        @"approvalPolicy": @"never"
    };
    [self sendRequest:@"turn/start" params:params tag:@"turn/start"];
    [self.delegate codexClient:self didAppendTranscript:[NSString stringWithFormat:@"\nYou: %@\nCodex: ", clean]];
}

- (void)readDirectory:(NSString *)path {
    NSString *target = path.length ? path : self.cwd;
    [self sendRequest:@"fs/readDirectory" params:@{ @"path": target ?: @"/" } tag:[@"fs:" stringByAppendingString:target ?: @"/"]];
}

- (void)runCommand:(NSString *)command {
    NSString *clean = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!clean.length) return;
    NSDictionary *params = @{
        @"command": @[ @"/bin/sh", @"-lc", clean ],
        @"cwd": self.cwd ?: @"/",
        @"timeoutMs": @60000,
        @"disableOutputCap": @YES
    };
    [self.delegate codexClient:self didAppendTerminal:[NSString stringWithFormat:@"\n$ %@\n", clean]];
    [self sendRequest:@"command/exec" params:params tag:@"command/exec"];
}

- (void)webSocketDidOpen:(CMWebSocket *)webSocket {
    [self.delegate codexClient:self didUpdateStatus:@"Initializing" connected:YES];
    NSDictionary *params = @{
        @"clientInfo": @{
            @"name": @"codex_ios12_mobile",
            @"title": @"Codex Mobile iOS 12",
            @"version": @"0.1"
        }
    };
    [self sendRequest:@"initialize" params:params tag:@"initialize"];
}

- (void)webSocket:(CMWebSocket *)webSocket didReceiveText:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![message isKindOfClass:[NSDictionary class]]) return;

    NSNumber *responseId = message[@"id"];
    if (responseId) {
        NSString *tag = self.pending[responseId];
        [self.pending removeObjectForKey:responseId];
        NSDictionary *error = message[@"error"];
        if ([error isKindOfClass:[NSDictionary class]]) {
            NSString *errorText = error[@"message"] ?: @"Request failed.";
            [self.delegate codexClient:self didUpdateStatus:errorText connected:YES];
            [self.delegate codexClient:self didAppendTerminal:[NSString stringWithFormat:@"error: %@\n", errorText]];
            return;
        }
        [self handleResponse:message[@"result"] tag:tag];
        return;
    }

    NSString *method = message[@"method"];
    NSDictionary *params = message[@"params"];
    if (![method isKindOfClass:[NSString class]]) return;
    if ([method isEqualToString:@"item/agentMessage/delta"]) {
        NSString *delta = params[@"delta"];
        if ([delta isKindOfClass:[NSString class]]) [self.delegate codexClient:self didAppendTranscript:delta];
    } else if ([method isEqualToString:@"item/reasoning/summaryTextDelta"]) {
        NSString *delta = params[@"delta"];
        if ([delta isKindOfClass:[NSString class]]) [self.delegate codexClient:self didAppendTranscript:delta];
    } else if ([method isEqualToString:@"turn/completed"]) {
        [self.delegate codexClient:self didAppendTranscript:@"\n"];
        [self.delegate codexClient:self didUpdateStatus:@"Ready" connected:YES];
    } else if ([method isEqualToString:@"command/exec/outputDelta"]) {
        NSString *encoded = params[@"deltaBase64"];
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:encoded ?: @"" options:0];
        NSString *chunk = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
        if (chunk.length) [self.delegate codexClient:self didAppendTerminal:chunk];
    }
}

- (void)webSocket:(CMWebSocket *)webSocket didCloseWithError:(NSError *)error {
    NSString *status = error.localizedDescription ?: @"Disconnected";
    [self.delegate codexClient:self didUpdateStatus:status connected:NO];
}

- (void)handleResponse:(id)result tag:(NSString *)tag {
    if ([tag isEqualToString:@"initialize"]) {
        [self sendNotification:@"initialized" params:nil];
        NSDictionary *params = @{
            @"cwd": self.cwd ?: @"/",
            @"sandbox": @"workspaceWrite",
            @"approvalPolicy": @"never",
            @"serviceName": @"codex_ios12_mobile"
        };
        [self sendRequest:@"thread/start" params:params tag:@"thread/start"];
    } else if ([tag isEqualToString:@"thread/start"]) {
        NSDictionary *thread = [result isKindOfClass:[NSDictionary class]] ? result[@"thread"] : nil;
        self.threadId = [thread isKindOfClass:[NSDictionary class]] ? thread[@"id"] : nil;
        [self.delegate codexClient:self didUpdateStatus:(self.threadId.length ? @"Ready" : @"No thread id") connected:YES];
        [self.delegate codexClient:self didAppendTranscript:@"Connected to Codex app-server.\n"];
        [self readDirectory:self.cwd];
    } else if ([tag hasPrefix:@"fs:"]) {
        NSDictionary *dict = [result isKindOfClass:[NSDictionary class]] ? result : nil;
        NSArray *entries = [dict[@"entries"] isKindOfClass:[NSArray class]] ? dict[@"entries"] : @[];
        NSString *path = [tag substringFromIndex:3];
        [self.delegate codexClient:self didUpdateFiles:entries path:path];
    } else if ([tag isEqualToString:@"command/exec"]) {
        NSDictionary *dict = [result isKindOfClass:[NSDictionary class]] ? result : nil;
        NSString *stdoutText = dict[@"stdout"];
        NSString *stderrText = dict[@"stderr"];
        NSNumber *exitCode = dict[@"exitCode"];
        if (stdoutText.length) [self.delegate codexClient:self didAppendTerminal:stdoutText];
        if (stderrText.length) [self.delegate codexClient:self didAppendTerminal:stderrText];
        [self.delegate codexClient:self didAppendTerminal:[NSString stringWithFormat:@"\n[exit %@]\n", exitCode ?: @0]];
    }
}

- (void)sendRequest:(NSString *)method params:(NSDictionary *)params tag:(NSString *)tag {
    NSNumber *requestId = @(self.nextId++);
    self.pending[requestId] = tag ?: method;
    NSMutableDictionary *message = [@{ @"id": requestId, @"method": method } mutableCopy];
    if (params) message[@"params"] = params;
    [self sendMessage:message];
}

- (void)sendNotification:(NSString *)method params:(NSDictionary *)params {
    NSMutableDictionary *message = [@{ @"method": method } mutableCopy];
    if (params) message[@"params"] = params;
    [self sendMessage:message];
}

- (void)sendMessage:(NSDictionary *)message {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.socket sendText:text];
}

@end
