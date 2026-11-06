#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

// Validates the TLS peer against only the roots imported in the pairing record.
BOOL LocSignVerifyPairingTrust(SecTrustRef peerTrust, NSArray *trustedRoots,
                               NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
