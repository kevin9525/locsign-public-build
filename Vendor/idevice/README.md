# idevice integration

LocSign uses the MIT-licensed `jkcoxson/idevice` v0.1.68, commit
`d32c8189c51c2789496b0768039419c3705498c3`. Its API is not source-compatible across
point releases. The Objective-C adapter is authored for the generated header at
that exact revision. No StikDebug application source is included.

The released XCFramework archive has SHA256
`c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7` (213,480,984 bytes).
It contains `swift/IDevice.xcframework`, module `IDevice`, including its plist FFI.
The upstream `swift/Package.swift` does not describe the actual release archive.
The generated header appends libplist's `plist.h` interface declarations, which
remain LGPL-2.1-or-later; see `LICENSE-libplist-header.txt` and the intact header
copyright. The linked implementation of those calls is the MIT Rust `plist_ffi`
crate, not the C libplist library. Production builds collect dependency license
texts into the packaged `LocationDDI/ThirdPartyNotices.txt` resource.
The release supports arm64 iOS devices and arm64/x86_64 iOS simulators. Symbol
inspection found no unprefixed OpenSSL API exports; release iOS slices use
Rustls/AWS-LC. This is a preliminary compatibility check, not a link-test result.

Production builds run `python3 .ci/build-idevice.py` using Rust 1.94.0 and compile
the same pinned source with LocSign's bounded FFI
operations. The original binary is suitable only for the initial compile probe:
upstream DVT/RSD calls can wait indefinitely. Every native session remains on
one dedicated Thread. An expired operation drops its Rust future before returning
an error; the adapter then releases the session on that same Thread. Calls use
30 seconds except image-mounter operations (120 seconds). The build runs tests
which verify timeout drops the future before the caller can release resources.
A location
set must retain its connection and is resent every five seconds. App suspension,
VPN loss, or a failed request means location state is unknown until a new device
acknowledgment. A disconnected session is not proof of real GPS restoration.

Developer image assets are downloaded during build and checked again on device.
They are not committed to this repository. The iOS 18-era build `16E5121h` comes
from `doronz88/DeveloperDiskImage` commit
`fc0dcfc99cdfd6973e4a2e01c6e75ed01b1e6171`, directory
`PersonalizedImages/Xcode_iOS_DDI_Personalized`. The three SHA256 pins are in
`.ci/prepare-idevice.py`. Image and trustcache SHA384 match the build manifest's
identity for iPhone16,2 (iPhone 15 Pro Max, board 0x06 / chip 0x8130).
Every mount still requests Apple's per-device personalization and requires
developer mode. The presence of a compatible build identity does not prove
successful mounting on a particular iOS release; real-device acceptance remains
required.

The DDI files are Apple's property as shipped with Xcode, mirrored for developer
interoperability by https://github.com/doronz88/DeveloperDiskImage. They are not
covered by the idevice MIT license. LocSign does not bypass image personalization.

Build integration: add `build/idevice/IDevice.xcframework` as a non-embedded
framework dependency, add `build/idevice/LocationDDI` as a folder resource, and
import `Engines/Location/LSDeviceLocationSession.h` from the app bridging header.
Neither pairing records nor credentials are included in generated resources.
