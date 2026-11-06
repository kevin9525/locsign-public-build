# XKit dependency probe

LocSign evaluates Xtool XKit at revision `2af0b67447d30063235e2adb7bdc77012f431d3a`.
The package declares Swift tools 6.2 and an iOS 17 platform floor. The app links the locally adapted XKit library. DeveloperAPI and XUtils are
also exposed as products for explicit network and storage adapter injection.

## First macOS probe

Run [42172604893](https://github.com/kevin9525/locsign/actions/runs/42172604893)
used Xcode 26.3 (17C529), Swift 6.2.4. Resolution failed before either build:
`multiple packages ('openssl', 'xtool-core') declare targets with a conflicting name: 'OpenSSL'`.
No Swift tests ran in this run. The four Python packaging tests passed locally.

The next probe uses the MIT source of xtool-core 1.5.1 at
`154d7213c12e3f21d50793f50ec7bfb89cfd3918` in `Vendor/xtool-core` with a
manifest adaptation to reuse existing OpenSSL 3.6.5000. See its LOCSIGN.md.
This is a candidate fix pending package resolution, both builds and regression tests.

The macOS CI job must record the Xcode version, Swift version, resolved package
versions, simulator build result, and unsigned iphoneos build result before the
provisioning implementation proceeds. A Windows checkout cannot run these
commands because it has no Xcode or swift toolchain.

The probe specifically checks for conflicts between XKit's xtool-core/OpenSSL
dependency and LocSign's existing OpenSSL/Zsign packages. A failed probe blocks
Apple ID provisioning code; it must not be bypassed by lowering the deployment
target or disabling TLS/profile validation.

## Minimal library integration

Run 42178034490 resolved packages but Xcode rejected duplicate OpenSSL products.
The source of XKit at the same pinned commit is now preserved in `Vendor/xtool`
with its MIT license; both native consumers share OpenSSL 3.6.5000.

Run 42179274685 passed resolution and reached compilation, then both builds
failed with `Unable to find module dependency: RCodesignBinary`. The subsequent
probe excludes XKit's signing, installation, and high-level provisioning flows.
It compiles the authentication and lower-level Developer Services surface only.
This avoids importing a second signing/device stack and matches the approved
architecture. The xtool-core adaptation contains only Superutils and ProtoCodable
products; no Rust, libimobiledevice, or duplicate OpenSSL target is needed.

Run [42182947194](https://github.com/kevin9525/locsign/actions/runs/42182947194)
at `e64ea5f` passed both the generic iOS Simulator build and unsigned iPhone
Release build using Xcode 26.3 / Swift 6.2.4. XCTest executed 65 tests, with one
failure in a pre-existing provisioning test whose expected logout scope was
incorrect; the other 64 tests passed. Full-suite success remains a separate gate.

See [resolved versions and licenses](Resolved.md). HTTPClientProtocol,
RawADIProvider and KeyValueStorage are public dependency injection points.
ClientInfoWithUserAgent needs an explicit public initializer for a custom
external RawADIProvider; this small source adaptation is scheduled with the
provider adapter and its tests. The default upstream HTTP/storage implementations
are not suitable for account credentials and must be overridden before live use.
