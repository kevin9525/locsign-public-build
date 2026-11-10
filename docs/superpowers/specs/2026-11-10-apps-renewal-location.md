# App management, renewal, and fixed-point location

Approved scope: existing 2026-11-04 design, user's request to add an App list, renewal and virtual location; user selected best-effort background renewal, foreground catch-up and failure notifications on 2026-11-10. Continue the established implementation without another approval cycle.

## Apps and renewal

- Persist original IPA files in protected, backup-excluded Application Support storage. Records bind original bundle, actual signing bundle, Apple account name, team and verified device UDID. Never persist private keys, tokens or pairing credentials in the catalog.
- Display managed Apps with actual last successful profile/certificate expiry, last outcome, renewal toggle, manual renewal and removal of local records/IPA. Removal does not uninstall the device App. Separately browse user Apps from installation_proxy; an unmanaged App needs its original IPA installed once to enable renewal.
- Save a pending installation before upload, and mark installed only after the install service confirms success. An interrupted attempt keeps the previous confirmed expiry. Self replacement remains pending until a subsequent launch verifies the running bundle's embedded profile. Never infer renewal from signing alone.
- Retain original signing identifier, team and device on renewal. Revalidate them before network mutation or upload. Do not silently switch a renewed App to the selected team or another device.
- Renewal requires a validated profile expiry strictly later than the previously confirmed expiry and at least 48 hours beyond now. Filter both local cached material and remotely listed/created profiles. Preserve existing normal-install reuse and strict CMS/key/device/team validation. Never automatically delete profiles or approve certificate revocation.
- Default auto-renewal for successfully managed Apps, with a global user switch. Attempt when effective expiry is within 48 hours, in expiry order; persist a six-hour retry time before beginning each attempt. Foreground catch-up and BGProcessingTask share one queue and the existing device operation lock.
- No prompting in an automatic run. Missing/expired login, provider consent, certificate revocation, missing IPA/pairing or changed device becomes an actionable failure. Respect protected-data availability and keep Keychain/file protection unchanged. BG task expiration cancels the pipeline; only completed installation advances expiry. Notifications contain App name and generic action, not credentials or device IDs.
- Automatic self-replacement is deferred to a foreground manual action because installing the running App terminates it. Preserve pending recovery evidence before upload. Bundle identity must match the running App to treat it as self.

## Location

- Map point selection, address search, manual coordinates, apply and restore real location; no routes or joystick.
- Use pinned MIT idevice FFI APIs through a narrow owned adapter, never copy GPL application implementation. Connect using saved pairing and VPN host; reuse operation exclusion for setup/apply/clear.
- Support iOS 18 via CoreDevice proxy, in-process TCP tunnel, RSD and DVT LocationSimulation. Check developer mode / personalized Developer Disk Image status and provide actionable setup. Mounting needs verified compatible DDI resources and Apple's personalization response, not arbitrary binaries.
- Coordinate validation rejects nonfinite and out-of-range values. Run blocking FFI on a serial worker, own/free every handle exactly once. Set simulated state only after the device accepts the request. On disconnect retain an unknown state and offer restore; do not falsely claim real GPS restored.
- Pin archive checksum, verify license and simulator/device slices; avoid linking conflicting OpenSSL implementations. Existing signing/TLS/heartbeat implementation remains the validated baseline.

## Validation and delivery

macos-15-intel CI: behavioral XCTest for persistence, renewal eligibility, minimum expiry, device/team identity, browse pagination, cancellation and coordinate bounds; simulator/device build and existing packaging suite. Windows has no Xcode; do not describe unavailable local XCTest as run. Private history and real credentials stay out of the public build mirror. Deliver unsigned IPA with version, SHA256 and honest device-test limits.
