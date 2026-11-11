#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// All methods and destruction belong to the creating Thread, never a dispatch queue.
@interface LSDeviceLocationSession : NSObject
+ (BOOL)validatePairingData:(NSData *)pairingData error:(NSError * _Nullable * _Nullable)error;
- (nullable instancetype)initWithHost:(NSString *)host
                         pairingData:(NSData *)pairingData
                        ddiDirectory:(nullable NSURL *)ddiDirectory
                               error:(NSError * _Nullable * _Nullable)error;
- (BOOL)applyLatitude:(double)latitude longitude:(double)longitude error:(NSError * _Nullable * _Nullable)error;
- (BOOL)restoreWithError:(NSError * _Nullable * _Nullable)error;
- (void)close;
@end

NS_ASSUME_NONNULL_END
