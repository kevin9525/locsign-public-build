# Provisioning profile trust anchors

Downloaded over HTTPS from Apple PKI on 2026-11-06. Only these explicit anchors are trusted; CMS-carried roots never become trust anchors.

| File | Apple source | SHA-256 |
|---|---|---|
| AppleIncRootCertificate.cer | https://www.apple.com/appleca/AppleIncRootCertificate.cer | `b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024` |
| AppleRootCA-G2.cer | https://www.apple.com/certificateauthority/AppleRootCA-G2.cer | `c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050` |
| AppleRootCA-G3.cer | https://www.apple.com/certificateauthority/AppleRootCA-G3.cer | `63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179` |

Profile signer policy follows the public Apple Security source implementation of `SecPolicyCreateiPhoneProvisioningProfileSigning`: a three-certificate chain anchored at Apple, leaf CN `Apple iPhone OS Provisioning Profile Signing`, issuer CN `Apple iPhone Certification Authority`. Source: https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.c . This is a policy reference only; no private Security API is linked. LocSign additionally verifies current certificate validity, CMS content/signature, a single signer, complete input consumption, digital signature key usage, and profile metadata before use.
