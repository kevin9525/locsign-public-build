#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

SecIdentityRef _Nullable LocSignCreateIdentity(SecCertificateRef certificate,
                                               NSData *privateKeyData)
    CF_RETURNS_RETAINED;

@interface LSDeviceSocket : NSObject

- (nullable instancetype)initWithHost:(NSString *)host
                                 port:(uint16_t)port
                              timeout:(NSTimeInterval)timeout
                                error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendRawData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;
- (nullable NSData *)readRawLength:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error;
- (BOOL)startTLSWithIdentity:(SecIdentityRef)identity
             certificateChain:(NSArray *)certificateChain
                  trustedRoots:(NSArray *)trustedRoots
                         error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendTLSData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;
- (nullable NSData *)readTLSLength:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error;
// Safe from another thread: wakes I/O without releasing the TLS context or FD.
- (void)interrupt;
- (void)close;

@end

NS_ASSUME_NONNULL_END
