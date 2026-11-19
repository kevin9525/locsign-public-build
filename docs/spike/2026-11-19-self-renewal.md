# LocSign expiry, reminders and self-renewal entry

The user selected improving LocSign's own expiry reminders and renewal entry before implementing a second copy or evaluating a LiveContainer installation. This extends the existing manual self-renewal flow. It does not enable automatic self-replacement, remove signing expiry, or install another app.

Apple's [membership comparison](https://developer.apple.com/support/compare-memberships/) states that Personal Team profiles expire seven days after issuance and permits three installed apps per device. Two signer copies can help only while at least one remains valid, and consume two slots. [LiveContainer](https://github.com/LiveContainer/LiveContainer) runs guest apps; its [official installation guide](https://livecontainer.github.io/docs/installation) offers a one-slot LiveContainer + SideStore build, where SideStore provides signing/refreshing. The host still requires a valid signature. No compatibility claim is made for LocSign inside LiveContainer, including shortcut callbacks and background tasks. No upstream code was copied.

## Behavior

- The App page reads the currently installed embedded provisioning profile, authenticates its CMS with the existing Apple roots and checks its allowed bundle identity and dates. Show its actual expiry even when LocSign was installed by a PC and is absent from the managed library. Missing/invalid metadata is unknown, never assumed to last another seven days. The displayed profile expiry is not a certificate-revocation check.
- An explicit local notification switch schedules reminders at 48 and 24 hours before that expiry. Past thresholds are not backfilled; the screen displays imminent expiry. The system receives pending notifications in advance, without requiring a background renewal job to wake. OS permission, notification settings and delivery still apply. Only this feature's two identifiers are replaced/removed, and updates are serialized so a late add cannot survive disabling.
- A uniquely matching managed self record with an available source uses the existing manual renewal confirmation. The minimum expiry also includes the actual installed profile, covering an external update newer than the catalog.
- Without a usable record, import a LocSign IPA in a dedicated signing sheet. Fix the target to the installed bundle ID and team, reject unrelated source IPA identities and a paired device outside the installed profile. Require a strictly later profile expiry and more than 48 hours of certificate validity before signing. Save the original IPA using the existing pending-install journal; only a later launch with the matching embedded profile confirms the self-update. The normal installation selection is kept separate.
- Explain recovery: if LocSign already cannot launch, use the original Apple ID and bundle identity in a PC signing tool or a still-valid configured signer to cover-update; do not uninstall first if local data must be preserved.

## Validation

Behavioral tests were written before the production changes. They cover authenticated/invalid/expired own-profile reading, reminder thresholds, renewal replacing pending notification dates, permission refusal, notification errors, late-add/disable races, exact self identity, device/team/source mismatch, ineffective renewal rejection and the installed-profile minimum overriding an older catalog. Windows cannot run XCTest; no local red baseline was observed. The macOS CI result and package evidence are recorded below.

Independent review found no critical or important issue. A minor stale-notification-error race was corrected: an in-flight request can no longer publish its result after reminders are disabled, while explicit permission-denial guidance remains visible. The delayed-add scenario now covers both success and failure, waiting for the disabled state. Follow-up review found no further issue.

macOS [CI run 44525604446](https://github.com/kevin9525/locsign-public-build/actions/runs/44525604446) succeeded for source `d5cf7855d64cbaae19b4aab5a499512f9e2850dc`: 418 XCTest cases with zero failures (13 added), 16 native tests (10 + 6), and 8 packaging tests. Simulator compilation and unsigned arm64 device compilation both passed. The delivered IPA was checked for version 0.4.6/build 25, original bundle ID, callback scheme, background mode, required roots/licenses, DDI hashes, unsigned packaging, and ZIP CRC integrity.

- File: `LocSign-0.4.6-build25-unsigned.ipa`
- Size: 24863857 bytes
- SHA-256: `9ebab8122d1f97381c375eeebce7bf520c5ea54bb032500df989584ea1e36a12`

Physical-device acceptance remains unverified for this version: actual notification delivery, PC cover-update preserving existing data, and self replacement followed by the next launch must be tested on-device. This is not a promise of background self-renewal or perpetual signing.
