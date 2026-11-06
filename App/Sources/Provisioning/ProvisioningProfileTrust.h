#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns authenticated embedded content only; errors never include raw CMS/key bytes.
NSData * _Nullable LocSignVerifyProvisioningCMS(NSData *cmsData, NSArray<NSData *> *trustAnchors,
                                                NSDate *now);
NSDate * _Nullable LocSignVerifyProvisioningCertificate(NSData *certificateDER, NSData *privateKeyPEM,
                                                        NSDate *now);

NS_ASSUME_NONNULL_END
