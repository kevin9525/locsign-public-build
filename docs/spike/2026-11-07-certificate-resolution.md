# Developer certificate response compatibility

LocSign 0.2.3 can report an invalid response at “申请开发证书” after pairing and app identifier registration. This operation includes both legacy certificate issuance and subsequent REST resource resolution, so that message does not establish whether issuance failed.

The gateway required the certificate collection to repeat the issued certificate's DER. `certificateContent` is optional, and both the vendored XKit certificate fetch operation and AltSign's certificate model allow association using a serial number. A metadata-only record therefore cannot be resolved by the existing equality check even when issuance returned a certificate.

The bounded repair parses the issued X.509 certificate, resolves exactly one REST resource by its numerical hexadecimal serial, preserves the issued DER, and requires any repeated REST certificate content to match. Legacy request identifiers must never replace REST resource identifiers. Duplicate serial records, mismatching content and unrelated serials are rejected. Certificate/private-key and signed profile validation still run before any material can be used.

Fixed diagnostics distinguish an unreadable certificate issuance response from a missing or conflicting REST certificate record. No response bodies, headers, account identifiers or key material are included. The change does not introduce automatic CSR resubmission or certificate revocation.

Reference inspection:

- Vendored `Vendor/xtool/Sources/XKit/DeveloperServices/Certificates/DeveloperServicesFetchCertificateOperation.swift` matches serial numbers.
- Vendored `Vendor/xtool/Sources/XKit/Model/Certificate.swift` parses X.509 serials and normalizes hexadecimal case/leading zeros.
- [AltSign certificate model](https://github.com/rileytestut/AltSign/blob/master/AltSign/Model/Apple%20API/ALTCertificate.m) accepts certificate metadata without content.
- [AltSign Apple API](https://github.com/rileytestut/AltSign/blob/master/AltSign/Apple%20API/ALTAppleAPI.m) reads legacy `certRequest` data.

RED verification ran 204 XCTest cases: the two new cases failed for the intended reasons and the previous 202 passed. The metadata-only fixture reproduced the same `createCertificate.invalidResponse` failure reported by the user. [RED run](https://github.com/kevin9525/locsign-public-build/actions/runs/42370003524); its later device build was superseded, but the completed simulator test log is retained.

Independent review found no introduced blocker. [GREEN run](https://github.com/kevin9525/locsign-public-build/actions/runs/42371240623), source `19ffa114e524e724ac9ed450821e8e4561c0f90f`, completed successfully: all 208 XCTest cases, including the six added certificate regressions; four packaging tests; simulator/device builds; and IPA assembly. The downloaded IPA was verified as 0.2.4 / build 10, retaining `com.locsign.LocSign`, with required resources, valid CRCs and unsigned state. Size: 12,909,301 bytes. SHA256: `7622af31b15d9eb7a35cdbbb82ce0f1390670b7717c74c7cff47117cedf3c0f1`. The user's exact response has not been captured, so live Apple issuance and installation still require device confirmation after delivery.

Existing recovery limit: if an older version received a certificate but failed before storing it, only the pending private key/CSR may remain. Recovery currently requires certificate bytes from the collection. The new serial association fixes a successful fresh issuance, but does not guarantee recovery of that older certificate when the collection omits its bytes. A user retry can still reach the existing certificate quota confirmation. No new automatic resubmission or revocation was added. The instance endpoint also models certificate content as optional, so it cannot be claimed to guarantee recovery without live evidence.
