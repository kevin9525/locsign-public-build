# Location pairing record compatibility

## Observed failure

LocSign 0.4.0 (19) reported “读取配对文件失败（错误码 13）” on applying a fixed location. The user subsequently confirmed maps displayed normally, so this change does not alter MapKit.

With the user's iPhone unlocked, a read-only USB inspection of LocSign's saved record found an XML dictionary containing HostID, SystemBUID, HostCertificate, HostPrivateKey and RootCertificate. DeviceCertificate, RootPrivateKey and WiFiMACAddress were absent. The host identity matched the existing USB pairing. Only field types/presence were recorded; no real credentials were copied into source, fixtures or public build artifacts.

The installer accepts this minimal record and authenticates TLS against its imported root. The pinned idevice parser additionally requires fields that are not needed by the existing installer, and returns UnexpectedResponse (13) before opening its own network connection. Repeatedly changing VPN settings cannot repair this local parse error.

## Fix

- Read the actual device leaf only after the existing pairing-root verification and complete TLS handshake succeed. The socket clears it on close and exposes nothing on failure or before authentication.
- Build an in-memory native record using the same HostID/SystemBUID and verified host certificate/private key. Normalize certificate and RSA key encoding for the Rust parser. Revalidate the device leaf against the imported root; if a full input record already contains a device certificate, require an exact DER match.
- Supply empty RootPrivateKey and WiFiMACAddress when the native schema needs them. The selected ring/TCP path does not use a root signing key or a MAC address. Never invent a device certificate or copy a root signing secret.
- Preserve optional escrow metadata. Do not modify the user's saved pairing file. Both apply and restore pass the transient prepared record to the native worker; disconnect clears the cached record.
- Replace the pinned upstream Rust verifier's unconditional acceptance with exact device-leaf pinning and TLS 1.2/1.3 handshake-signature verification. The pin comes from the preceding authenticated connection. The standard pairing checks remain in the existing transport.
- Separate native parsing errors from developer-mode, VPN and network instructions.

## Validation

XCTest covers the original minimal-record code 13, conversion accepted by the real native parser, XML/binary and PEM/DER forms, distinct host/device certificates, escrow preservation, rejection of mismatched/untrusted/expired/tampered device certificates and invalid host keys. Existing socket integration tests also assert that peer certificate export is available only after a successful authenticated handshake and is cleared on close.

Ten native Rust tests exercise real in-memory TLS 1.2/1.3 handshakes for a valid pinned Apple-shaped certificate, same-key/different-certificate substitution, root substitution, corrupt handshake signatures, absent pins and mismatched client identity. Six existing native timeout/ownership tests remain enabled.

Validation on [macOS CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42939673036) (public source `6478182aa08c28eb556d554a586a27516b736304`): 371 XCTest passed, including all 10 LocationPairingTests and the existing socket tests; 10 Rust TLS handshake tests and 6 native timeout/ownership tests passed; 8 Python build-tool tests passed. Simulator and device builds and IPA assembly succeeded. The downloaded 0.4.1 (20) IPA passed arm64/version/identifier/resources/background configuration/DDI checksum/CRC verification. The original minimal-file code13 and adapted parser acceptance are directly covered by tests; actual device image preparation and GPS behavior remain separate acceptance items.

## Device acceptance

Update using the same Apple ID and LocSign identifier. Keep the existing saved pairing file, enable LocalDevVPN and developer mode, unlock the phone, and apply the same selected point. The original local parse error should no longer block developer-service preparation. Confirm the resulting location in the device Maps app, then request restoration and confirm the actual position. First-time personalized image mounting and real GPS behavior require device validation independently of parser/TLS tests.
