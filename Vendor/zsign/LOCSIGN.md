# Zsign source snapshot

Upstream: https://github.com/khcrysalis/Zsign-Package

Revision: `c4ba9da4283031c07efa03bce42c4b8602d22e73`

License: MIT; the original LICENSE is preserved here and in the app's third-party
notices. This directory contains the upstream Swift package's compiled source
files and headers. Unused CLI, archive implementation, bundled third-party
libraries, build projects and test binaries are omitted. ZIPFoundation continues
to unpack/repack IPAs; OpenSSL remains the existing shared package dependency.

## Local changes

- `src/bundle.cpp`: write the selected embedded profile when `bRemoveProvision`
  is **false**, before generating CodeResources and signing the executable.
  The old inverted condition removed the profile for either flag value.
- `src/bundle.cpp` (`SignNode`, multi-profile path only): select each bundle's
  profile by exact application identifier (`<prefix>.<bundle id>`) instead of
  a suffix match, and embed it **before** generating that bundle's
  CodeResources. Upstream wrote nested profiles after sealing (the same
  `0xe8008017` class of error fixed above for the main app) and wrote them
  twice. An app or extension with no matching profile now fails instead of
  silently reusing another bundle's identity; frameworks still use the main
  app's identity. The single-profile path is unchanged.
- `swift/zsign.mm`, `swift/zsign.hpp`, `swift/zsign.swift`: add
  `zsignWithProvisions` / `Zsign.sign(appPath:provisionPaths:...)`, which signs
  with one key and one profile/entitlements pair per bundle (main app first).
- `Package.swift`: replace exclusions for omitted source files with exclusions
  for this snapshot's license and provenance documents. Build settings, compiled
  source lists, public API and dependencies retain their upstream values.

`upstream.patch` records the complete changes to retained upstream files.
IPAPackerTests exercises the real SigningEngine with absent and stale original
profiles, checking the final profile bytes, both resource hashes, and both
CodeDirectory resource special slots after repackaging. Device installation is
still the end-to-end acceptance check.
