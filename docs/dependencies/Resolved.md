# Resolved dependencies

Verified resolution and dual-platform builds: [CI 42182947194](https://github.com/kevin9525/locsign/actions/runs/42182947194), Xcode 26.3 / Swift 6.2.4.

The checked-in `.ci/Package.resolved` preserves the exact remote revisions below. XcodeGen copies it into the generated workspace before resolution. Local adaptations are documented in each vendor directory; upstream source is pinned, not a moving branch.

| Package | Version | Revision | License file |
|---|---|---|---|
| bigint | 6.0.1 | `63feef7820abb1a8fb08587d7da56bb0b7db8751` | [license](licenses/bigint.txt) |
| combine-schedulers | 1.2.2 | `114354e8c1667a2edc4993700fb9fa4f90157b56` | [license](licenses/combine-schedulers.txt) |
| openssl | 3.6.5000 | `0a6149bff4fb00921ce0ec1811f726b166638095` | [license](licenses/openssl.txt) |
| swift-asn1 | 1.7.4 | `917b472dbe53ba699cbb0495f9a95a084bc6364d` | [license](licenses/swift-asn1.txt) |
| swift-certificates | 1.21.1 | `84f03fafeca28c19f5fc4b528df3d22ce8896bd7` | [license](licenses/swift-certificates.txt) |
| swift-clocks | 1.1.1 | `82440fa0a8b1c381a6d1e8e0fc7bbba53ec63204` | [license](licenses/swift-clocks.txt) |
| swift-collections | 1.7.5 | `f96b909e1a9e469620bc5037c1e24e00153f376f` | [license](licenses/swift-collections.txt) |
| swift-concurrency-extras | 1.4.3 | `8a4260f7373493435bd21194585c95b72bfdd401` | [license](licenses/swift-concurrency-extras.txt) |
| swift-crypto | 5.1.1 | `f8fad2f95ad67b45f6340c0960e2396094d67e07` | [license](licenses/swift-crypto.txt) |
| swift-dependencies | 1.17.2 | `2f83b70a6fbf45795dd40ccaa907bad3c8d93fe1` | [license](licenses/swift-dependencies.txt) |
| swift-http-types | 1.8.0 | `bff4b6903cdc99dda49649dd52f46c11cfd3ed50` | [license](licenses/swift-http-types.txt) |
| swift-openapi-runtime | 1.13.4 | `b9ebb3f06f1dac717156a04f0919ad444cbcf8f5` | [license](licenses/swift-openapi-runtime.txt) |
| swift-openapi-urlsession | 1.4.0 | `c97e0f0187d95542b4a254f5bb4dc67f43bf73c9` | [license](licenses/swift-openapi-urlsession.txt) |
| swift-subprocess | 1.0.2 | `dbe21bd7dfd4ffef8c32588918542a8abfa1b54c` | [license](licenses/swift-subprocess.txt) |
| swift-syntax | 604.0.0 | `050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf` | [license](licenses/swift-syntax.txt) |
| swift-system | 1.8.1 | `869129b7bf4ecc57b97d0193ad29690ca2134750` | [license](licenses/swift-system.txt) |
| xctest-dynamic-overlay | 1.13.1 | `d9308ad679143c26a30dec52daefe82f54af2b82` | [license](licenses/xctest-dynamic-overlay.txt) |
| zipfoundation | 0.9.20 | `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | [license](licenses/zipfoundation.txt) |
| zsign-package | local profile-seal patch | `c4ba9da4283031c07efa03bce42c4b8602d22e73` | [license](licenses/zsign-package.txt) |

Locally preserved source:

- xtool/XKit: `2af0b67447d30063235e2adb7bdc77012f431d3a`, MIT; `Vendor/xtool/LICENSE.md` and `LOCSIGN.md`.
- xtool-core: `154d7213c12e3f21d50793f50ec7bfb89cfd3918` (1.5.1), MIT; `Vendor/xtool-core/LICENSE.md` and `LOCSIGN.md`.

Swift Crypto also supplies [NOTICE](licenses/swift-crypto-NOTICE.txt). Package licenses include their upstream exceptions and notices. Build-only dependencies (such as SwiftSyntax and macOS Subprocess) are listed as resolved even when they do not ship in the iOS executable. RCodesign and SwiftyMobileDevice are not in the resolved graph.
