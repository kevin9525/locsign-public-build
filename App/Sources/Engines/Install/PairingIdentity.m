#import "DeviceSocket.h"
#import <OpenSSL/err.h>
#import <OpenSSL/pem.h>
#import <OpenSSL/pkcs12.h>
#import <limits.h>

static int LSNoKeyPassword(char *buffer, int size, int writing, void *context) {
    return 0;
}

// SecPKCS12Import is supported on iOS and returns an in-memory identity. Do not
// use the private SecIdentityCreate symbol or persist pairing keys in Keychain.
SecIdentityRef LocSignCreateIdentity(SecCertificateRef certificate, NSData *privateKeyData) {
    if (privateKeyData.length == 0 || privateKeyData.length > INT_MAX) return NULL;
    NSData *certificateData = CFBridgingRelease(SecCertificateCopyData(certificate));
    const unsigned char *certificateBytes = certificateData.bytes;
    X509 *x509 = d2i_X509(NULL, &certificateBytes, (long)certificateData.length);
    if (!x509) return NULL;

    BIO *keyBIO = BIO_new_mem_buf(privateKeyData.bytes, (int)privateKeyData.length);
    EVP_PKEY *key = keyBIO ? PEM_read_bio_PrivateKey(keyBIO, NULL, LSNoKeyPassword, NULL) : NULL;
    BIO_free(keyBIO);
    if (!key) {
        ERR_clear_error();
        const unsigned char *keyBytes = privateKeyData.bytes;
        key = d2i_AutoPrivateKey(NULL, &keyBytes, (long)privateKeyData.length);
        if (key && keyBytes != (const unsigned char *)privateKeyData.bytes + privateKeyData.length) {
            EVP_PKEY_free(key);
            key = NULL;
        }
    }

    SecIdentityRef identity = NULL;
    PKCS12 *container = NULL;
    unsigned char *encoded = NULL;
    CFArrayRef imported = NULL;
    do {
        if (!key || X509_check_private_key(x509, key) != 1) break;
        NSString *password = NSUUID.UUID.UUIDString;
        container = PKCS12_create(password.UTF8String, "LocSign pairing", key, x509, NULL,
                                  NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
                                  NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, 2048, 0);
        if (!container || PKCS12_set_mac(container, password.UTF8String, -1, NULL, 0, 2048, EVP_sha1()) != 1) break;
        int length = i2d_PKCS12(container, &encoded);
        if (length <= 0) break;
        NSData *data = [NSData dataWithBytes:encoded length:(NSUInteger)length];
        NSDictionary *options = @{(__bridge id)kSecImportExportPassphrase: password};
        OSStatus status = SecPKCS12Import((__bridge CFDataRef)data, (__bridge CFDictionaryRef)options, &imported);
        if (status != errSecSuccess || !imported || CFArrayGetCount(imported) != 1) break;
        CFDictionaryRef item = CFArrayGetValueAtIndex(imported, 0);
        SecIdentityRef result = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
        if (result && CFGetTypeID(result) == SecIdentityGetTypeID()) identity = (SecIdentityRef)CFRetain(result);
    } while (0);

    if (imported) CFRelease(imported);
    OPENSSL_free(encoded);
    PKCS12_free(container);
    EVP_PKEY_free(key);
    X509_free(x509);
    ERR_clear_error();
    return identity;
}
