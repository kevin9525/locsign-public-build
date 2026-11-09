# Embedded profile missing from the resource seal

## Observed failure

On LocSign 0.2.8 (14), a device reproduction reached installation verification
for a signed Feather 2.9.0 IPA. The install source was LocSign's unique
`PublicStaging/LocSign-<operation>/app.ipa` path. iOS reported `resource added`,
`0xe8008017` (a signed resource has been added, modified, or deleted), and
`MIInstallerErrorDomain` code 13. This reproduction passed the earlier network
heartbeat/upload failure point.

Read-only inspection of the app's four cached signed IPAs found the same issue
in each: `embedded.mobileprovision` existed in the archive but had no entry in
`_CodeSignature/CodeResources`. All 77 listed SHA-256 resource hashes matched,
the ZIP CRC checks passed, and the executable's SHA-1 and SHA-256 CodeDirectories
both sealed the actual CodeResources bytes. The unlisted profile explains the
resource-added failure without changing accounts, pairing or networking.

## Cause and correction

The pinned Zsign commit `c4ba9da4283031c07efa03bce42c4b8602d22e73` deletes the
embedded profile in `ZBundle::SignFolder`, then writes it back only when
`bRemoveProvision` is true. `GenerateCodeResources` also removes it when that
flag is true. Neither flag value retains and seals the profile. LocSign's
post-sign restoration made the file present but could not add it to the seal.

The bounded correction retains the same upstream source as a local dependency,
changes the inverted retention condition, and replaces LocSign's post-sign
write with a read-only consistency check. All bundle writes must finish before
the resource manifest and its executable signature are produced.

## Verification

The real SigningEngine regression cases cover an IPA with no original profile
and an IPA with a stale profile. They inspect the final repackaged output,
compare both resource hashes against the selected profile, and check that both
Mach-O CodeDirectories seal the final manifest. This catches a manifest edited
after signing as well as the original unsealed-file defect.

RED CI run `42570009351` (source `10142d3940fdb5775b7c71c105c146b14c8671a7`)
ran all 250 tests: both signing cases failed at the missing profile resource-seal
entry (three assertions including the existing catch/report assertion); the
other cases passed. A separate assertion against the actual device IPA failed
for the same missing entry. Four local packaging tests passed. Independent
read-only review found no blocking issue in the targeted patch or package wiring.

GREEN CI run `42571719945` (source `69b11bf776774410fd743da061600f41faedfd2a`)
passed all 250 XCTest cases with zero failures, including both real signing
regressions. Four packaging tests, simulator/device builds and IPA assembly
passed. The downloaded unsigned IPA was verified as 0.2.9 (15), original
`com.locsign.LocSign`, with required bundled resources and valid ZIP CRCs.

- Size: 12,944,118 bytes
- SHA-256: `3a9b1d1acc7938cb2ff1ac079a42584b9601f62e44ab190dc9f6d3fff09d5cc1`

Production code/config and signing regression tests match the tested public
snapshot. Three pre-existing public fixture/document/parser-test redactions
remain intentionally different from the private repository.

Device logs and signed artifacts contain private
material and remain outside tracked/public source. A fresh device installation
after re-signing remains the acceptance check; existing signed IPAs are not
repaired by upgrading LocSign.
