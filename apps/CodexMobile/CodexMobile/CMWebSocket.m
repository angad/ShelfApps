#import "CMWebSocket.h"
#import <Security/Security.h>

static NSString *CMWebSocketErrorDomain = @"CMWebSocketErrorDomain";

@interface CMWebSocket () <NSStreamDelegate>

@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSInputStream *inputStream;
@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, strong) NSMutableData *inputBuffer;
@property (nonatomic, strong) NSMutableData *outputBuffer;
@property (nonatomic, strong) NSMutableData *fragmentBuffer;
@property (nonatomic) BOOL sentHandshake;
@property (nonatomic) BOOL receivedHandshake;
@property (nonatomic) BOOL closed;
@property (nonatomic) UInt8 fragmentOpcode;

@end

@implementation CMWebSocket

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers {
    self = [super init];
    if (self) {
        _url = url;
        _headers = [headers copy] ?: @{};
        _inputBuffer = [NSMutableData data];
        _outputBuffer = [NSMutableData data];
        _fragmentBuffer = [NSMutableData data];
    }
    return self;
}

- (void)connect {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.inputStream || self.outputStream) return;
        NSString *host = self.url.host;
        NSNumber *port = self.url.port;
        BOOL secure = [self.url.scheme.lowercaseString isEqualToString:@"wss"];
        NSInteger resolvedPort = port ? port.integerValue : (secure ? 443 : 80);
        if (host.length == 0) {
            [self closeStreamsWithError:[self errorWithCode:10 message:@"Missing WebSocket host."]];
            return;
        }

        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, (UInt32)resolvedPort, &readStream, &writeStream);
        self.inputStream = CFBridgingRelease(readStream);
        self.outputStream = CFBridgingRelease(writeStream);

        if (secure) {
            NSDictionary *sslSettings = @{ (__bridge NSString *)kCFStreamSSLPeerName: host };
            [self.inputStream setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
            [self.outputStream setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
            [self.inputStream setProperty:sslSettings forKey:(__bridge NSString *)kCFStreamPropertySSLSettings];
            [self.outputStream setProperty:sslSettings forKey:(__bridge NSString *)kCFStreamPropertySSLSettings];
        }

        self.inputStream.delegate = self;
        self.outputStream.delegate = self;
        [self.inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [self.outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [self.inputStream open];
        [self.outputStream open];
    });
}

- (void)sendText:(NSString *)text {
    if (text.length == 0) return;
    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.receivedHandshake || self.closed) return;
        [self.outputBuffer appendData:[self frameWithOpcode:0x1 payload:payload]];
        [self flushOutput];
    });
}

- (void)close {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed) return;
        if (self.receivedHandshake) {
            [self.outputBuffer appendData:[self frameWithOpcode:0x8 payload:[NSData data]]];
            [self flushOutput];
        }
        [self closeStreamsWithError:nil];
    });
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    if (eventCode == NSStreamEventOpenCompleted) {
        if (aStream == self.outputStream && !self.sentHandshake) [self sendHandshake];
    } else if (eventCode == NSStreamEventHasBytesAvailable) {
        [self readAvailableBytes];
    } else if (eventCode == NSStreamEventHasSpaceAvailable) {
        [self flushOutput];
    } else if (eventCode == NSStreamEventErrorOccurred) {
        NSError *error = aStream.streamError ?: [self errorWithCode:1 message:@"WebSocket stream error."];
        [self closeStreamsWithError:error];
    } else if (eventCode == NSStreamEventEndEncountered) {
        [self closeStreamsWithError:nil];
    }
}

- (void)sendHandshake {
    self.sentHandshake = YES;
    NSString *path = self.url.path.length ? self.url.path : @"/";
    if (self.url.query.length) path = [path stringByAppendingFormat:@"?%@", self.url.query];
    NSString *host = self.url.host;
    if (self.url.port) host = [host stringByAppendingFormat:@":%@", self.url.port];
    NSMutableString *request = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\n", path, host, [self randomHandshakeKey]];
    for (NSString *header in self.headers) {
        [request appendFormat:@"%@: %@\r\n", header, self.headers[header]];
    }
    [request appendString:@"\r\n"];
    [self.outputBuffer appendData:[request dataUsingEncoding:NSUTF8StringEncoding]];
    [self flushOutput];
}

- (NSString *)randomHandshakeKey {
    NSMutableData *data = [NSMutableData dataWithLength:16];
    if (SecRandomCopyBytes(kSecRandomDefault, data.length, data.mutableBytes) != errSecSuccess) {
        arc4random_buf(data.mutableBytes, data.length);
    }
    return [data base64EncodedStringWithOptions:0];
}

- (NSData *)frameWithOpcode:(UInt8)opcode payload:(NSData *)payload {
    NSMutableData *frame = [NSMutableData data];
    UInt8 first = 0x80 | (opcode & 0x0f);
    [frame appendBytes:&first length:1];

    UInt64 length = payload.length;
    UInt8 maskBit = 0x80;
    if (length < 126) {
        UInt8 value = maskBit | (UInt8)length;
        [frame appendBytes:&value length:1];
    } else if (length <= UINT16_MAX) {
        UInt8 value = maskBit | 126;
        UInt16 networkLength = CFSwapInt16HostToBig((UInt16)length);
        [frame appendBytes:&value length:1];
        [frame appendBytes:&networkLength length:2];
    } else {
        UInt8 value = maskBit | 127;
        UInt64 networkLength = CFSwapInt64HostToBig(length);
        [frame appendBytes:&value length:1];
        [frame appendBytes:&networkLength length:8];
    }

    UInt8 mask[4];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(mask), mask) != errSecSuccess) {
        arc4random_buf(mask, sizeof(mask));
    }
    [frame appendBytes:mask length:sizeof(mask)];

    NSMutableData *masked = [payload mutableCopy];
    UInt8 *bytes = masked.mutableBytes;
    for (NSUInteger i = 0; i < masked.length; i++) bytes[i] ^= mask[i % 4];
    [frame appendData:masked];
    return frame;
}

- (void)flushOutput {
    if (self.outputBuffer.length == 0 || !self.outputStream.hasSpaceAvailable) return;
    NSInteger written = [self.outputStream write:self.outputBuffer.bytes maxLength:self.outputBuffer.length];
    if (written > 0) {
        [self.outputBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)written) withBytes:NULL length:0];
    } else if (written < 0) {
        NSError *error = self.outputStream.streamError ?: [self errorWithCode:2 message:@"WebSocket write failed."];
        [self closeStreamsWithError:error];
    }
}

- (void)readAvailableBytes {
    UInt8 buffer[8192];
    while (self.inputStream.hasBytesAvailable) {
        NSInteger count = [self.inputStream read:buffer maxLength:sizeof(buffer)];
        if (count > 0) {
            [self.inputBuffer appendBytes:buffer length:(NSUInteger)count];
        } else if (count < 0) {
            NSError *error = self.inputStream.streamError ?: [self errorWithCode:3 message:@"WebSocket read failed."];
            [self closeStreamsWithError:error];
            return;
        } else {
            break;
        }
    }
    if (!self.receivedHandshake && ![self parseHandshake]) return;
    [self parseFrames];
}

- (BOOL)parseHandshake {
    NSData *needle = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange range = [self.inputBuffer rangeOfData:needle options:0 range:NSMakeRange(0, self.inputBuffer.length)];
    if (range.location == NSNotFound) return NO;

    NSData *headerData = [self.inputBuffer subdataWithRange:NSMakeRange(0, range.location + range.length)];
    NSString *headers = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    [self.inputBuffer replaceBytesInRange:NSMakeRange(0, range.location + range.length) withBytes:NULL length:0];

    if (![headers hasPrefix:@"HTTP/1.1 101"] && ![headers hasPrefix:@"HTTP/1.0 101"]) {
        [self closeStreamsWithError:[self errorWithCode:4 message:headers.length ? headers : @"WebSocket upgrade rejected."]];
        return NO;
    }
    self.receivedHandshake = YES;
    [self.delegate webSocketDidOpen:self];
    return YES;
}

- (void)parseFrames {
    while (self.inputBuffer.length >= 2) {
        const UInt8 *bytes = self.inputBuffer.bytes;
        UInt8 first = bytes[0];
        UInt8 second = bytes[1];
        BOOL final = (first & 0x80) != 0;
        UInt8 opcode = first & 0x0f;
        BOOL masked = (second & 0x80) != 0;
        UInt64 length = second & 0x7f;
        NSUInteger offset = 2;

        if (length == 126) {
            if (self.inputBuffer.length < offset + 2) return;
            UInt16 networkLength = 0;
            memcpy(&networkLength, bytes + offset, 2);
            length = CFSwapInt16BigToHost(networkLength);
            offset += 2;
        } else if (length == 127) {
            if (self.inputBuffer.length < offset + 8) return;
            UInt64 networkLength = 0;
            memcpy(&networkLength, bytes + offset, 8);
            length = CFSwapInt64BigToHost(networkLength);
            offset += 8;
        }

        UInt8 mask[4] = {0, 0, 0, 0};
        if (masked) {
            if (self.inputBuffer.length < offset + 4) return;
            memcpy(mask, bytes + offset, 4);
            offset += 4;
        }
        if (self.inputBuffer.length < offset + length) return;

        NSData *payload = [self.inputBuffer subdataWithRange:NSMakeRange(offset, (NSUInteger)length)];
        [self.inputBuffer replaceBytesInRange:NSMakeRange(0, offset + (NSUInteger)length) withBytes:NULL length:0];
        if (masked) {
            NSMutableData *unmasked = [payload mutableCopy];
            UInt8 *payloadBytes = unmasked.mutableBytes;
            for (NSUInteger i = 0; i < unmasked.length; i++) payloadBytes[i] ^= mask[i % 4];
            payload = unmasked;
        }
        [self handleFrameWithOpcode:opcode final:final payload:payload];
    }
}

- (void)handleFrameWithOpcode:(UInt8)opcode final:(BOOL)final payload:(NSData *)payload {
    if (opcode == 0x8) {
        [self closeStreamsWithError:nil];
        return;
    }
    if (opcode == 0x9) {
        [self.outputBuffer appendData:[self frameWithOpcode:0xA payload:payload ?: [NSData data]]];
        [self flushOutput];
        return;
    }
    if (opcode == 0xA) return;

    if (opcode == 0x1 || opcode == 0x2) {
        [self.fragmentBuffer setLength:0];
        self.fragmentOpcode = opcode;
        [self.fragmentBuffer appendData:payload];
    } else if (opcode == 0x0) {
        [self.fragmentBuffer appendData:payload];
    } else {
        return;
    }
    if (!final) return;

    if (self.fragmentOpcode == 0x1) {
        NSString *text = [[NSString alloc] initWithData:self.fragmentBuffer encoding:NSUTF8StringEncoding];
        if (text) [self.delegate webSocket:self didReceiveText:text];
    }
    [self.fragmentBuffer setLength:0];
    self.fragmentOpcode = 0;
}

- (void)closeStreamsWithError:(NSError *)error {
    if (self.closed) return;
    self.closed = YES;
    [self.inputStream close];
    [self.outputStream close];
    [self.inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.inputStream.delegate = nil;
    self.outputStream.delegate = nil;
    self.inputStream = nil;
    self.outputStream = nil;
    [self.delegate webSocket:self didCloseWithError:error];
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:CMWebSocketErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"WebSocket error."}];
}

@end
