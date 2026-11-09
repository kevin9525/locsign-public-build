#import "DeviceSocket.h"
#import "PairingTrust.h"
#import <Security/SecureTransport.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <poll.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdio.h>
#import <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString * const LSDeviceSocketErrorDomain = @"LocSign.DeviceSocket";

@interface LSDeviceSocket ()
@property (nonatomic, assign) int socketFD;
@property (nonatomic, assign, nullable) SSLContextRef tlsContext;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, assign) NSTimeInterval operationDeadline;
- (int)fileDescriptor;
- (BOOL)prepareIO;
@end

static NSError *LSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LSDeviceSocketErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static OSStatus LSReadCallback(SSLConnectionRef connection, void *data, size_t *length) {
    LSDeviceSocket *socket = (__bridge LSDeviceSocket *)connection;
    size_t requested = *length;
    size_t received = 0;
    while (received < requested) {
        if (![socket prepareIO]) { *length = received; return errSecIO; }
        ssize_t count = recv(socket.fileDescriptor, (uint8_t *)data + received, requested - received, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            *length = received;
            return count == 0 ? errSSLClosedGraceful : errSecIO;
        }
        received += (size_t)count;
    }
    *length = received;
    return noErr;
}

static OSStatus LSWriteCallback(SSLConnectionRef connection, const void *data, size_t *length) {
    LSDeviceSocket *socket = (__bridge LSDeviceSocket *)connection;
    size_t requested = *length;
    size_t sent = 0;
    while (sent < requested) {
        if (![socket prepareIO]) { *length = sent; return errSecIO; }
        ssize_t count = send(socket.fileDescriptor, (const uint8_t *)data + sent, requested - sent, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { *length = sent; return errSecIO; }
        sent += (size_t)count;
    }
    *length = sent;
    return noErr;
}

@implementation LSDeviceSocket

- (int)fileDescriptor { return self.socketFD; }

- (BOOL)prepareIO {
    NSTimeInterval remaining = self.operationDeadline - NSProcessInfo.processInfo.systemUptime;
    if (remaining <= 0) { errno = ETIMEDOUT; return NO; }
    struct timeval timeout = {.tv_sec = (time_t)remaining,
                              .tv_usec = (suseconds_t)((remaining - (time_t)remaining) * 1000000)};
    if (timeout.tv_sec == 0 && timeout.tv_usec == 0) timeout.tv_usec = 1;
    return setsockopt(self.socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
           setsockopt(self.socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

- (nullable instancetype)initWithHost:(NSString *)host port:(uint16_t)port
                              timeout:(NSTimeInterval)timeout error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    self.socketFD = -1;
    self.tlsContext = NULL;
    if (!isfinite(timeout) || timeout <= 0 || timeout > 300) {
        if (error) *error = LSError(EINVAL, @"设备连接超时设置无效");
        return nil;
    }
    self.timeout = timeout;

    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    char portText[8];
    snprintf(portText, sizeof(portText), "%u", port);
    struct addrinfo *addresses = NULL;
    int lookup = getaddrinfo(host.UTF8String, portText, &hints, &addresses);
    if (lookup != 0) {
        if (error) *error = LSError(lookup, [NSString stringWithUTF8String:gai_strerror(lookup)]);
        return nil;
    }

    int timeoutMilliseconds = (int)(MAX(0.1, timeout) * 1000.0);
    int lastError = ETIMEDOUT;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd < 0) { lastError = errno; continue; }
        int noSIGPIPE = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, sizeof(noSIGPIPE));

        int oldFlags = fcntl(fd, F_GETFL, 0);
        if (oldFlags < 0 || fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) < 0) {
            lastError = errno; close(fd); continue;
        }
        int result = connect(fd, address->ai_addr, address->ai_addrlen);
        if (result < 0 && errno == EINPROGRESS) {
            struct pollfd pollDescriptor = {.fd = fd, .events = POLLOUT};
            result = poll(&pollDescriptor, 1, timeoutMilliseconds);
            if (result > 0) {
                socklen_t errorLength = sizeof(lastError);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &lastError, &errorLength) < 0) lastError = errno;
                result = lastError == 0 ? 0 : -1;
            } else {
                lastError = result == 0 ? ETIMEDOUT : errno;
                result = -1;
            }
        } else if (result < 0) {
            lastError = errno;
        }
        if (result == 0 && fcntl(fd, F_SETFL, oldFlags) == 0) {
            struct timeval socketTimeout = {.tv_sec = (time_t)timeout,
                                            .tv_usec = (suseconds_t)((timeout - (time_t)timeout) * 1000000)};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, sizeof(socketTimeout));
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, sizeof(socketTimeout));
            self.socketFD = fd;
            break;
        }
        if (result == 0) lastError = errno;
        close(fd);
    }
    freeaddrinfo(addresses);
    if (self.socketFD < 0) {
        if (error) *error = LSError(lastError, [NSString stringWithFormat:@"连接设备服务失败（%d）", lastError]);
        return nil;
    }
    return self;
}

- (BOOL)sendBytes:(const uint8_t *)bytes length:(NSUInteger)length error:(NSError **)error {
    self.operationDeadline = NSProcessInfo.processInfo.systemUptime + self.timeout;
    NSUInteger offset = 0;
    while (offset < length) {
        ssize_t count = [self prepareIO] ? send(self.socketFD, bytes + offset, length - offset, 0) : -1;
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int code = errno ?: EIO;
            if (error) *error = LSError(code, [NSString stringWithFormat:@"发送设备消息失败（%d）", code]);
            return NO;
        }
        offset += (NSUInteger)count;
    }
    return YES;
}

- (BOOL)sendRawData:(NSData *)data error:(NSError **)error {
    return [self sendBytes:data.bytes length:data.length error:error];
}

- (nullable NSData *)readRawLength:(NSUInteger)length error:(NSError **)error {
    self.operationDeadline = NSProcessInfo.processInfo.systemUptime + self.timeout;
    NSMutableData *result = [NSMutableData dataWithLength:length];
    uint8_t *bytes = result.mutableBytes;
    NSUInteger offset = 0;
    while (offset < length) {
        ssize_t count = [self prepareIO] ? recv(self.socketFD, bytes + offset, length - offset, 0) : -1;
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int code = count == 0 ? ECONNRESET : (errno ?: EIO);
            if (error) *error = LSError(code, [NSString stringWithFormat:@"读取设备消息失败（%d）", code]);
            return nil;
        }
        offset += (NSUInteger)count;
    }
    return result;
}

- (BOOL)startTLSWithIdentity:(SecIdentityRef)identity
             certificateChain:(NSArray *)certificateChain
                  trustedRoots:(NSArray *)trustedRoots
                         error:(NSError **)error {
    if (self.tlsContext) return YES;
    if (trustedRoots.count == 0) {
        if (error) *error = LSError(errSecParam, @"缺少设备配对信任根证书");
        return NO;
    }
    self.operationDeadline = NSProcessInfo.processInfo.systemUptime + self.timeout;
    self.tlsContext = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
    if (!self.tlsContext) {
        if (error) *error = LSError(errSecAllocate, @"创建 TLS 会话失败");
        return NO;
    }

    OSStatus status = SSLSetIOFuncs(self.tlsContext, LSReadCallback, LSWriteCallback);
    if (status == noErr) status = SSLSetConnection(self.tlsContext, (__bridge SSLConnectionRef)self);
    if (status == noErr) status = SSLSetProtocolVersionMin(self.tlsContext, kTLSProtocol12);
    if (status == noErr) status = SSLSetProtocolVersionMax(self.tlsContext, kTLSProtocol12);
    if (status == noErr) status = SSLSetSessionOption(self.tlsContext, kSSLSessionOptionBreakOnServerAuth, true);

    NSMutableArray *chain = [NSMutableArray arrayWithObject:(__bridge id)identity];
    [chain addObjectsFromArray:certificateChain];
    if (status == noErr) status = SSLSetCertificate(self.tlsContext, (__bridge CFArrayRef)chain);

    NSError *verificationError = nil;
    while (status == noErr || status == errSSLWouldBlock || status == errSSLPeerAuthCompleted) {
        if (NSProcessInfo.processInfo.systemUptime >= self.operationDeadline) { status = errSSLNetworkTimeout; break; }
        status = SSLHandshake(self.tlsContext);
        if (status == errSSLPeerAuthCompleted) {
            SecTrustRef trust = NULL;
            OSStatus trustStatus = SSLCopyPeerTrust(self.tlsContext, &trust);
            if (trustStatus == noErr && !trust) trustStatus = errSSLXCertChainInvalid;
            if (trustStatus == noErr && trust) {
                SecTrustSetNetworkFetchAllowed(trust, false);
                if (!LocSignVerifyPairingTrust(trust, trustedRoots, &verificationError)) {
                    trustStatus = errSSLXCertChainInvalid;
                }
                CFRelease(trust);
            }
            if (trustStatus != noErr) status = trustStatus;
            else status = errSSLWouldBlock;
        }
        if (status == errSSLWouldBlock) continue;
        break;
    }

    if (status != noErr) {
        if (error) {
            NSMutableDictionary *info = [@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"配对 TLS 握手或设备证书验证失败（%d）%@", (int)status,
                 verificationError ? [@"：" stringByAppendingString:verificationError.localizedDescription] : @""]} mutableCopy];
            if (verificationError) info[NSUnderlyingErrorKey] = verificationError;
            *error = [NSError errorWithDomain:LSDeviceSocketErrorDomain code:status userInfo:info];
        }
        CFRelease(self.tlsContext);
        self.tlsContext = NULL;
        return NO;
    }
    return YES;
}

- (BOOL)sendTLSData:(NSData *)data error:(NSError **)error {
    self.operationDeadline = NSProcessInfo.processInfo.systemUptime + self.timeout;
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    while (offset < data.length) {
        if (NSProcessInfo.processInfo.systemUptime >= self.operationDeadline) {
            if (error) *error = LSError(errSSLNetworkTimeout, @"TLS 发送超时");
            return NO;
        }
        size_t written = 0;
        OSStatus status = SSLWrite(self.tlsContext, bytes + offset, data.length - offset, &written);
        if (status != noErr && status != errSSLWouldBlock) {
            if (error) *error = LSError(status, [NSString stringWithFormat:@"TLS 发送失败（%d）", (int)status]);
            return NO;
        }
        if (written == 0 && status == noErr) {
            if (error) *error = LSError(errSecIO, @"TLS 发送未取得进展");
            return NO;
        }
        offset += written;
    }
    return YES;
}

- (nullable NSData *)readTLSLength:(NSUInteger)length error:(NSError **)error {
    self.operationDeadline = NSProcessInfo.processInfo.systemUptime + self.timeout;
    NSMutableData *result = [NSMutableData dataWithLength:length];
    uint8_t *bytes = result.mutableBytes;
    size_t offset = 0;
    while (offset < length) {
        if (NSProcessInfo.processInfo.systemUptime >= self.operationDeadline) {
            if (error) *error = LSError(errSSLNetworkTimeout, @"TLS 接收超时");
            return nil;
        }
        size_t readCount = 0;
        OSStatus status = SSLRead(self.tlsContext, bytes + offset, length - offset, &readCount);
        if (status != noErr && status != errSSLWouldBlock) {
            if (error) *error = LSError(status, [NSString stringWithFormat:@"TLS 接收失败（%d）", (int)status]);
            return nil;
        }
        if (readCount == 0 && status == noErr) {
            if (error) *error = LSError(errSecIO, @"TLS 连接提前关闭");
            return nil;
        }
        offset += readCount;
    }
    return result;
}

- (void)interrupt {
    @synchronized (self) {
        if (self.socketFD >= 0) shutdown(self.socketFD, SHUT_RDWR);
    }
}

- (void)close {
    if (self.tlsContext) {
        self.operationDeadline = NSProcessInfo.processInfo.systemUptime + MIN(self.timeout, 0.1);
        SSLClose(self.tlsContext);
        CFRelease(self.tlsContext);
        self.tlsContext = NULL;
    }
    // Serialize descriptor release with interrupt to prevent shutting down an
    // unrelated socket if the OS reuses this descriptor after close.
    @synchronized (self) {
        if (self.socketFD >= 0) {
            shutdown(self.socketFD, SHUT_RDWR);
            close(self.socketFD);
            self.socketFD = -1;
        }
    }
}

- (void)dealloc { [self close]; }

@end

#pragma clang diagnostic pop
