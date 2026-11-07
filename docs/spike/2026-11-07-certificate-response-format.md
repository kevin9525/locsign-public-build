# Certificate issuance response formats

The user reports the specific certificate issuance response error after 0.2.4. This identifies a failure decoding the legacy issuance response or parsing the returned X.509 certificate, before REST certificate resource resolution. The actual response bytes have not been captured.

The current implementation treats binary certificate fields as DER and accepts strings only as base64. A PEM-encoded certificate in either a plist data field or a string therefore fails. [AltSign's certificate model at 1c44cfd](https://github.com/rileytestut/AltSign/blob/1c44cfdcafc1ef301c9a0a20a96be0983bb5a003/AltSign/Model/Apple%20API/ALTCertificate.m) explicitly supports PEM and DER, and reads both `certContent` and `certificateContent` field names.

The bounded fix normalizes these supported encodings into one validated DER certificate before REST resolution. It accepts only a single complete PEM certificate, permits ASCII whitespace in base64, rejects extra data/ambiguous fields, and uses the existing X.509 parser. Subsequent serial association, private-key correspondence and profile verification remain required.

Fixed safe diagnostics distinguish invalid envelopes, missing certificate records/content, unsupported field types, empty/oversized content, invalid encoding, invalid X.509 and ambiguous content. Diagnostics contain no raw response, identifiers or keys. Apple rejection codes remain classified before the certificate payload is decoded.

RED verification: [run 42377683609](https://github.com/kevin9525/locsign-public-build/actions/runs/42377683609) completed 210 XCTest cases with two failures, exclusively the new PEM-data and PEM-string cases. Both reproduced `createCertificate.certificateResponseInvalid`; the previous 208 passed. The later device build was superseded after that evidence was saved.

GREEN verification completed successfully for [run 42378999851](https://github.com/kevin9525/locsign-public-build/actions/runs/42378999851), source `870ca18dd65390b0eb7d382f931564d65d74222b`, version 0.2.5 / build 11: 216 XCTest cases with zero failures, four packaging tests, simulator/device builds and IPA assembly. Eight added tests cover supported PEM/base64 forms, precise diagnostics, malformed/multiple PEM, trailing/non-certificate ASN.1, content size and Apple rejection codes without certificate fields. Independent code review found no outstanding issues.

The downloaded unsigned IPA retains `com.locsign.LocSign`; version/build, required resources and CRCs were verified. Size: 12,920,972 bytes. SHA256: `df62f7cac07ee19435563c2e5a14788873260967b30c8e5bede415b002b82907`.

Safe diagnostic categories:

| Code | Meaning |
| --- | --- |
| C01 | Invalid response envelope or result status |
| C02 | Missing or invalid certificate record |
| C03 | Missing certificate content |
| C04 | Unsupported certificate field type |
| C05 | Empty content |
| C06 | Content larger than 1 MiB |
| C07 | Invalid PEM/base64 encoding or extra content |
| C08 | Invalid X.509 certificate |
| C09 | Ambiguous certificate content fields |

This compatibility gap does not establish that the user's current Apple response is PEM; the new precise diagnostics will identify a remaining response-shape problem if present. Existing recovery limits for a previously issued but unsaved certificate still apply, as documented in the [0.2.4 investigation](2026-11-07-certificate-resolution.md). No automatic certificate revocation or CSR retry was added.
