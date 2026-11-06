#import "ProvisioningProfileTrust.h"
#import <OpenSSL/bio.h>
#import <OpenSSL/buffer.h>
#import <OpenSSL/cms.h>
#import <OpenSSL/err.h>
#import <OpenSSL/pem.h>
#import <OpenSSL/x509.h>
#import <OpenSSL/x509v3.h>
#import <limits.h>
#import <time.h>

static BOOL LSCommonNameEquals(X509_NAME *name, NSString *expected) {
    if (!name) return NO;
    int index = X509_NAME_get_index_by_NID(name, NID_commonName, -1);
    if (index < 0 || X509_NAME_get_index_by_NID(name, NID_commonName, index) >= 0) return NO;
    ASN1_STRING *value = X509_NAME_ENTRY_get_data(X509_NAME_get_entry(name, index));
    unsigned char *utf8 = NULL;
    int length = ASN1_STRING_to_UTF8(&utf8, value);
    if (length < 0 || !utf8) return NO;
    NSString *result = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    OPENSSL_free(utf8);
    return [result isEqualToString:expected];
}

static X509 *LSProfileCertificate(NSData *data) {
    if (data.length == 0 || data.length > 1024 * 1024) return NULL;
    const unsigned char *bytes = data.bytes;
    X509 *cert = d2i_X509(NULL, &bytes, (long)data.length);
    if (cert && bytes != (const unsigned char *)data.bytes + data.length) {
        X509_free(cert); return NULL;
    }
    return cert;
}

static BOOL LSAddTrustAnchors(X509_STORE *store, NSArray<NSData *> *anchors) {
    if (anchors.count == 0 || anchors.count > 16) return NO;
    for (NSData *data in anchors) {
        X509 *anchor = LSProfileCertificate(data);
        BOOL valid = anchor && X509_check_ca(anchor) > 0 && X509_STORE_add_cert(store, anchor) == 1;
        X509_free(anchor);
        if (!valid) return NO;
    }
    return YES;
}

NSData *LocSignVerifyProvisioningCMS(NSData *cmsData, NSArray<NSData *> *trustAnchors,
                                     NSDate *now) {
    if (cmsData.length == 0 || cmsData.length > 16 * 1024 * 1024) {
        return nil;
    }
    const unsigned char *bytes = cmsData.bytes;
    CMS_ContentInfo *cms = d2i_CMS_ContentInfo(NULL, &bytes, (long)cmsData.length);
    X509_STORE *store = X509_STORE_new();
    BIO *output = BIO_new(BIO_s_mem());
    STACK_OF(X509) *signers = NULL;
    STACK_OF(X509) *embedded = NULL;
    X509_STORE_CTX *context = X509_STORE_CTX_new();
    NSData *result = nil;
    do {
        if (!cms || bytes != (const unsigned char *)cmsData.bytes + cmsData.length || !store || !output || !context ||
            !LSAddTrustAnchors(store, trustAnchors)) break;
        if (OBJ_obj2nid(CMS_get0_type(cms)) != NID_pkcs7_signed || CMS_is_detached(cms) != 0 ||
            OBJ_obj2nid(CMS_get0_eContentType(cms)) != NID_pkcs7_data) break;
        STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(cms);
        if (!infos || sk_CMS_SignerInfo_num(infos) != 1) break;

        // Profiles are not S/MIME mail. Apply basic X.509 validation with an
        // explicit anchor store, then enforce Apple's profile signer policy below.
        X509_VERIFY_PARAM *parameters = X509_STORE_get0_param(store);
        if (X509_VERIFY_PARAM_set_purpose(parameters, X509_PURPOSE_ANY) != 1) break;
        X509_VERIFY_PARAM_set_time(parameters, (time_t)now.timeIntervalSince1970);
        X509_VERIFY_PARAM_set_depth(parameters, 2);
        X509_VERIFY_PARAM_set_auth_level(parameters, 1);
        // No CMS signature, content, signer, or chain verification bypass flags.
        if (CMS_verify(cms, NULL, store, NULL, output, CMS_BINARY) != 1) break;
        signers = CMS_get0_signers(cms);
        if (!signers || sk_X509_num(signers) != 1) break;
        X509 *signer = sk_X509_value(signers, 0);
        if (!LSCommonNameEquals(X509_get_subject_name(signer), @"Apple iPhone OS Provisioning Profile Signing") ||
            !LSCommonNameEquals(X509_get_issuer_name(signer), @"Apple iPhone Certification Authority") ||
            X509_check_ca(signer) != 0 || (X509_get_key_usage(signer) & KU_DIGITAL_SIGNATURE) == 0) break;
        embedded = CMS_get1_certs(cms);
        if (!embedded || X509_STORE_CTX_init(context, store, signer, embedded) != 1 ||
            X509_verify_cert(context) != 1) break;
        STACK_OF(X509) *chain = X509_STORE_CTX_get0_chain(context);
        if (!chain || sk_X509_num(chain) != 3) break;
        BUF_MEM *buffer = NULL;
        BIO_get_mem_ptr(output, &buffer);
        if (!buffer || !buffer->data || buffer->length == 0 || buffer->length > 8 * 1024 * 1024) break;
        result = [NSData dataWithBytes:buffer->data length:buffer->length];
    } while (0);
    X509_STORE_CTX_free(context);
    sk_X509_free(signers); // CMS owns the signer certificates.
    sk_X509_pop_free(embedded, X509_free);
    BIO_free(output); X509_STORE_free(store); CMS_ContentInfo_free(cms); ERR_clear_error();
    return result;
}

NSDate *LocSignVerifyProvisioningCertificate(NSData *certificateDER, NSData *privateKeyPEM,
                                            NSDate *now) {
    X509 *certificate = LSProfileCertificate(certificateDER);
    BIO *keyBIO = privateKeyPEM.length > 0 && privateKeyPEM.length < 1024 * 1024
        ? BIO_new_mem_buf(privateKeyPEM.bytes, (int)privateKeyPEM.length) : NULL;
    EVP_PKEY *key = keyBIO ? PEM_read_bio_PrivateKey(keyBIO, NULL, NULL, NULL) : NULL;
    time_t checkTime = (time_t)now.timeIntervalSince1970;
    BOOL valid = certificate && key && X509_check_private_key(certificate, key) == 1 &&
        EVP_PKEY_security_bits(key) >= 112 && X509_check_ca(certificate) == 0 &&
        X509_cmp_time(X509_get0_notBefore(certificate), &checkTime) < 0 &&
        X509_cmp_time(X509_get0_notAfter(certificate), &checkTime) > 0;
    NSDate *result = nil;
    struct tm expiry = {0};
    if (valid && ASN1_TIME_to_tm(X509_get0_notAfter(certificate), &expiry) == 1) {
        result = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)timegm(&expiry)];
    }
    EVP_PKEY_free(key); BIO_free(keyBIO); X509_free(certificate); ERR_clear_error();
    return result;
}
