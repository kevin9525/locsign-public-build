#import "PairingTrust.h"
#import <OpenSSL/err.h>
#import <OpenSSL/x509.h>
#import <OpenSSL/x509_vfy.h>
#import <OpenSSL/x509v3.h>
#import <limits.h>

static X509 *LSCopyX509(SecCertificateRef certificate) {
    NSData *data = CFBridgingRelease(SecCertificateCopyData(certificate));
    if (data.length == 0 || data.length > LONG_MAX) return NULL;
    const unsigned char *bytes = data.bytes;
    X509 *result = d2i_X509(NULL, &bytes, (long)data.length);
    if (result && bytes != (const unsigned char *)data.bytes + data.length) {
        X509_free(result);
        return NULL;
    }
    return result;
}

static int LSCheckPairingAlgorithms(X509 *certificate) {
    EVP_PKEY *key = X509_get0_pubkey(certificate);
    if (!key || EVP_PKEY_security_bits(key) < 112) return X509_V_ERR_EE_KEY_TOO_SMALL;
    int digest = NID_undef, keyAlgorithm = NID_undef, securityBits = 0;
    uint32_t flags = 0;
    if (X509_get_signature_info(certificate, &digest, &keyAlgorithm, &securityBits, &flags) != 1 ||
        (securityBits < 112 && digest != NID_sha1)) return X509_V_ERR_CA_MD_TOO_WEAK;
    return X509_V_OK;
}

static int LSCheckLegacyPairingShape(X509 *certificate, BOOL isRoot) {
    if (X509_NAME_entry_count(X509_get_subject_name(certificate)) != 0 ||
        X509_NAME_entry_count(X509_get_issuer_name(certificate)) != 0 ||
        (!isRoot && X509_get_ext_by_NID(certificate, NID_authority_key_identifier, -1) >= 0)) {
        return X509_V_ERR_INVALID_EXTENSION;
    }
    // This compatibility path supports only Apple's direct root/leaf format.
    // Reject all other extensions so root constraints cannot be lost when the
    // two certificates are validated separately (e.g. name constraints or EKU).
    for (int index = 0; index < X509_get_ext_count(certificate); index++) {
        X509_EXTENSION *extension = X509_get_ext(certificate, index);
        int nid = OBJ_obj2nid(X509_EXTENSION_get_object(extension));
        if (nid != NID_basic_constraints && nid != NID_subject_key_identifier &&
            nid != NID_key_usage && !(isRoot && nid == NID_authority_key_identifier)) {
            return X509_EXTENSION_get_critical(extension) ? X509_V_ERR_UNHANDLED_CRITICAL_EXTENSION
                                                        : X509_V_ERR_INVALID_EXTENSION;
        }
        if (X509_get_ext_by_NID(certificate, nid, index) >= 0) return X509_V_ERR_INVALID_EXTENSION;
    }
    BASIC_CONSTRAINTS *constraints = X509_get_ext_d2i(certificate, NID_basic_constraints, NULL, NULL);
    BOOL valid = constraints && (!!constraints->ca == !!isRoot) && (isRoot || !constraints->pathlen);
    BASIC_CONSTRAINTS_free(constraints);
    if (!valid) return isRoot ? X509_V_ERR_INVALID_CA : X509_V_ERR_INVALID_NON_CA;
    if (!isRoot && (X509_get_key_usage(certificate) & KU_DIGITAL_SIGNATURE) == 0) {
        return X509_V_ERR_KEYUSAGE_NO_DIGITAL_SIGNATURE;
    }
    return LSCheckPairingAlgorithms(certificate);
}

static int LSVerifyPinnedCertificate(X509 *certificate, unsigned long flags) {
    X509_STORE *store = X509_STORE_new();
    X509_STORE_CTX *context = X509_STORE_CTX_new();
    int result = X509_V_ERR_UNSPECIFIED;
    if (store && context && X509_STORE_add_cert(store, certificate) == 1 &&
        X509_STORE_CTX_init(context, store, certificate, NULL) == 1) {
        X509_VERIFY_PARAM *parameters = X509_STORE_CTX_get0_param(context);
        X509_VERIFY_PARAM_set_auth_level(parameters, 0);
        if (X509_VERIFY_PARAM_set_flags(parameters, flags) == 1) {
            result = X509_verify_cert(context) == 1 ? X509_V_OK : X509_STORE_CTX_get_error(context);
        }
    }
    X509_STORE_CTX_free(context);
    X509_STORE_free(store);
    return result;
}

static int LSVerifyLegacyPairingLeaf(X509 *leaf, NSArray *trustedRoots) {
    int result = LSCheckLegacyPairingShape(leaf, NO);
    if (result != X509_V_OK) return result;
    result = X509_V_ERR_CERT_SIGNATURE_FAILURE;
    for (id object in trustedRoots) {
        X509 *root = LSCopyX509((__bridge SecCertificateRef)object);
        if (!root) return X509_V_ERR_UNSPECIFIED;
        int candidate = LSCheckLegacyPairingShape(root, YES);
        if (candidate == X509_V_OK) candidate = X509_check_issued(root, leaf);
        if (candidate == X509_V_OK && X509_verify(leaf, X509_get0_pubkey(root)) != 1) {
            candidate = X509_V_ERR_CERT_SIGNATURE_FAILURE;
        }
        if (candidate == X509_V_OK) {
            candidate = LSVerifyPinnedCertificate(root, X509_V_FLAG_CHECK_SS_SIGNATURE);
        }
        X509_free(root);
        if (candidate != X509_V_OK) { result = candidate; continue; }
        // The exact peer leaf has now been cryptographically authenticated by
        // an imported, valid CA. Pin only this leaf in a temporary store to run
        // validity/extension checks without the broken self-issued chain guess.
        // Its signature was checked against the root above, never against itself.
        return LSVerifyPinnedCertificate(leaf, X509_V_FLAG_PARTIAL_CHAIN);
    }
    return result;
}

BOOL LocSignVerifyPairingTrust(SecTrustRef peerTrust, NSArray *trustedRoots, NSError **error) {
    // Apple pairing records use empty names, zero serials and SHA-1 signatures.
    // SecPolicyCreateBasicX509 rejects these names before validating their keys.
    // Use the existing OpenSSL dependency with a private, explicitly populated
    // trust store. No system roots, network fetching or trust exceptions apply.
    NSArray *peerCertificates = CFBridgingRelease(SecTrustCopyCertificateChain(peerTrust));
    X509_STORE *store = X509_STORE_new();
    X509_STORE_CTX *context = X509_STORE_CTX_new();
    STACK_OF(X509) *peers = sk_X509_new_null();
    BOOL verified = NO;
    int verificationCode = X509_V_ERR_UNSPECIFIED;
    do {
        if (!store || !context || !peers || peerCertificates.count == 0 ||
            peerCertificates.count > 16 || trustedRoots.count == 0 || trustedRoots.count > 16) break;
        BOOL parsed = YES;
        for (id object in trustedRoots) {
            if (CFGetTypeID((__bridge CFTypeRef)object) != SecCertificateGetTypeID()) { parsed = NO; break; }
            X509 *root = LSCopyX509((__bridge SecCertificateRef)object);
            if (!root) { parsed = NO; break; }
            verificationCode = LSCheckPairingAlgorithms(root);
            parsed = verificationCode == X509_V_OK && X509_STORE_add_cert(store, root) == 1;
            X509_free(root);
            if (!parsed) break;
        }
        if (!parsed) break;
        for (id object in peerCertificates) {
            if (CFGetTypeID((__bridge CFTypeRef)object) != SecCertificateGetTypeID()) { parsed = NO; break; }
            X509 *certificate = LSCopyX509((__bridge SecCertificateRef)object);
            if (!certificate || sk_X509_push(peers, certificate) == 0) {
                X509_free(certificate);
                parsed = NO;
                break;
            }
        }
        if (!parsed || X509_STORE_CTX_init(context, store, sk_X509_value(peers, 0), peers) != 1) break;
        X509_VERIFY_PARAM *parameters = X509_STORE_CTX_get0_param(context);
        // Level 0 permits Apple's SHA-1 pairing signatures. Key strength and
        // non-SHA-1 signature strength are checked explicitly above and below.
        X509_VERIFY_PARAM_set_auth_level(parameters, 0);
        X509_VERIFY_PARAM_set_depth(parameters, 15);
        if (X509_VERIFY_PARAM_set_flags(parameters, X509_V_FLAG_CHECK_SS_SIGNATURE) != 1) break;
        // Default verification retains certificate validity, signatures, CA
        // constraints, key usage and critical-extension checks.
        if (X509_verify_cert(context) != 1) {
            verificationCode = X509_STORE_CTX_get_error(context);
            if (verificationCode == X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT) {
                verificationCode = LSVerifyLegacyPairingLeaf(sk_X509_value(peers, 0), trustedRoots);
                verified = verificationCode == X509_V_OK;
            }
            break;
        }
        STACK_OF(X509) *chain = X509_STORE_CTX_get0_chain(context);
        verificationCode = X509_V_OK;
        for (int index = 0; index < sk_X509_num(chain); index++) {
            verificationCode = LSCheckPairingAlgorithms(sk_X509_value(chain, index));
            if (verificationCode != X509_V_OK) break;
        }
        verified = verificationCode == X509_V_OK;
    } while (0);
    X509_STORE_CTX_free(context);
    sk_X509_pop_free(peers, X509_free);
    X509_STORE_free(store);
    ERR_clear_error();
    if (!verified && error) {
        if (verificationCode == X509_V_OK) verificationCode = X509_V_ERR_UNSPECIFIED;
        NSString *detail = [NSString stringWithUTF8String:X509_verify_cert_error_string(verificationCode)];
        *error = [NSError errorWithDomain:@"LocSign.PairingTrust" code:verificationCode
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"设备证书校验未通过：%@", detail]}];
    }
    return verified;
}
