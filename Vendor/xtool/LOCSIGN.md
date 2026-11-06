# Source provenance

Repository: https://github.com/xtool-org/xtool
Commit: 2af0b67447d30063235e2adb7bdc77012f431d3a
License: MIT, preserved in LICENSE.md.

Sources/XKit, XUtils, CXKit, and DeveloperAPI were copied from this commit.
The local Package.swift selects these library targets, excludes CLI and Linux-only
dependencies, and makes CXKit use the same OpenSSL 3.6.5000 product as LocSign and
Zsign. DeveloperAPI and XUtils are explicit library products for adapter injection.
Native signing/installation continue to use LocSign's existing implementation.

CI 42172604893 rejected duplicate OpenSSL targets; CI 42178034490 resolved the
graph after renaming the target but rejected duplicate PACKAGE-PRODUCT:OpenSSL.
This manifest removes the duplicate product instead of aliasing it.

CI 42179274685 then reached compilation but failed on RCodesignBinary on both
iOS destinations. LocSign only needs GrandSlam, Anisette, the low-level Developer
Services clients, and their models. The manifest excludes upstream signing,
installation, and high-level provisioning orchestration and removes the RCodesign
and SwiftyMobileDevice dependencies. LocSign retains its existing Zsign and
device installation implementation. Excluded upstream sources remain here for
provenance; they are not compiled or linked into the app.

LocSign adds a public ClientInfoWithUserAgent initializer and a throwing,
provider-specific ADIDataProvider initializer. This entry point propagates
Keychain failures and resets ADI on provider changes. ADI supplies its own device
info to GrandSlam lookup to avoid capturing the default provider. Network and
storage injection are covered by synthetic handshake and cancellation tests.
DeveloperServicesLoginManager also exposes payload-free authentication error
classification so the app can map known status codes and 2FA cancellation without
logging server messages or matching localized strings.

The App Group identifier model remains compiled because the upstream entitlement
model references it. App Group mutations and provisioning orchestration remain
excluded. CI 42181881359 diagnosed this missing model dependency.
