# LocSign package adaptation

Source: https://github.com/xtool-org/xtool-core
Version: 1.5.1, commit 154d7213c12e3f21d50793f50ec7bfb89cfd3918 (MIT).

Source files and LICENSE.md are preserved. The adapted Package.swift exposes
only the pure Swift Superutils and ProtoCodable products used by LocSign's XKit
subset. It does not compile or download upstream native signing/device products.
XKit's CXKit target uses LocSign's existing OpenSSL 3.6.5000 package directly.

This resolves the duplicate OpenSSL target/product definitions found in CI runs
42172604893 and 42178034490. Simulator and iphoneos linking and existing
pairing/signing tests remain required verification gates.
