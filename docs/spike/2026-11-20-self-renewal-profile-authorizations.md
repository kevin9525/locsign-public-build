# Self-renewal with existing profile authorizations

Build26 on the device successfully completes the alternate capability read, then
rejects an existing App ID as unsupported. Read-only USB inspection found matching
LocSign profiles with App Groups and increased-memory-limit authorizations in
addition to the basic signing entitlements. These metadata observations alone do
not authenticate the profiles or prove which profile is embedded in the app. The
exact feature name in the failed request was not captured. The App Groups legacy
code `APG3427HIY` is documented in SideStore AltSign's `ALTCapabilities.swift` and
used by isideload's `dev/app_ids.rs`.

The repair normalizes that known code to `APP_GROUPS` and accepts that capability
on an exact matching App ID without enabling, disabling, or deleting remote
capabilities. Unknown capabilities still fail before mutation. A cryptographically
verified profile may carry an optional array of concrete `group.*` identifiers
and a boolean increased-memory-limit authorization. All other entitlement,
identity, team, device, certificate/private-key, and expiry checks remain active.

Profiles authorize a superset of the executable's claims. Automatic signing
removes these two unused authorizations from the executable entitlement plist;
it still embeds the original CMS bytes, seals them with the app, and uses only
the exact application's keychain group. LocSign uses its own container/default
keychain and does not use an App Group container. Preflight still rejects IPAs
that actually request these extra claims. Manual supplied-profile signing keeps
the explicit profile entitlements. The signing option is named
`automaticProvisioning` to describe both keychain narrowing and omission of these
unused authorizations. Existing bundle/team identity and app data are preserved
by covering the existing installation, with actual device acceptance still needed.

The tests use only public synthetic profiles. Baseline run `44660317802`, source
`8328028efdb4be641e4852429bd7c298f80f78df`, reproduced the existing-App-ID rejection,
missing legacy feature normalization, profile metadata rejection, and unintended
extra executable claims: 437 tests, six failed assertions in five new tests; all
429 previous tests passed. Additional integration tests inspect the actual signed
Mach-O entitlements and resource seals, and verify active/cached material validation.

Target release: 0.4.8 (27). Full green CI, independent review, artifact verification,
and device replacement/reopen/later-expiry acceptance remain pending.
