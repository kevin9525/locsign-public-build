# Self-renewal result confirmation

The user wants LocSign to renew itself while retaining its existing identity,
data and saved original IPA. A build28 reproduction showed `waitForResult`
TLS -9806, while the paired device's installation service recorded installation
success and failure to send completion to the client. After the user reopened
LocSign, its existing exact-profile reconciliation cleared pending/error state
and confirmed a later expiry. No development tool initiated installation or
revoked a certificate.

This bounded follow-up distinguishes an unconfirmed self-install result from
an explicit failure. Only a socket TLS closure while waiting after submission,
for the running bundle with a durable pending record, qualifies. Upload/send
failures, signature rejection, malformed responses, cancellation and certificate
validation failures remain errors. Ordinary app installation remains unchanged.

Self replacement retains the previously confirmed expiry and original IPA,
shows a neutral instruction to fully close and reopen LocSign, and prevents
another self-install in the same launch from overwriting its journal. Even a
successful installation-service completion for the running app waits for
relaunch verification. A later launch with the exact proposed embedded profile
confirms success; a mismatch remains unconfirmed and permits a deliberate retry.
No arbitrary -9806 is treated as success, and no security check is relaxed.

The change covers the App list renewal coordinator, the self-IPA import flow,
the existing journal, and their visible status. It does not add unattended self
replacement or a second signing app. Deliverables remain in the user's top-level
deliverables directory. Target version 0.4.10 (29).

Regression tests exercise both entry points, prevent duplicate submissions,
retain old expiry/source until exact-profile verification, and assert that
ordinary/explicit failures remain visible. Tests-only source
40e1b97baeab3ebd69c9bffd4db6a287f8478b25 in CI 44693233004 executed 448 tests,
with 12 failed assertions in the two new self-disconnect tests and the
strengthened self-completion test. Failures showed red error state, duplicate
uploads and premature success. The other 445 tests passed.

The implementation adds a machine-readable installation step alongside the
existing error/cause, an optional backward-compatible journal flag, and guarded
pending status in both entry points. It accepts only the DeviceSocket domain's
TLS closure codes -9805/-9806 at waitForResult. The journal flag is scoped to
the running bundle and attempt launch; after restart, unmatched attempts remain
visible but do not block deliberate retry. UI never labels this status success.
Code review found two target-identity edge cases: a global pending guard could
block ordinary app signing, and manual signing could retain an original bundle
identifier different from the automatic personal identifier. The final guard
uses the selected effective target and records the actual signed output identity.
Manual output reads the unique top-level Info.plist with a bounded extraction;
automatic output uses the provisioned identity. Clearing output clears its
identity. Shared-library and real manual-signing regression tests cover both
self and ordinary app targets with differing personal-identifier settings.

Follow-up review of e1aab3d found both issues resolved and no remaining important
findings. CI run 44700663270 for exact source
e1aab3ded34022dfaabc557fb1dad7480a38e346 completed successfully: 450 XCTest,
16 native service tests and 8 packaging tests passed, with successful simulator
and unsigned device builds. The private product/test/version files were checked
against that exact source before delivery.

Artifact 14613477966 was downloaded and verified for ZIP integrity, version
0.4.10/build29, arm64 executable, unsigned packaging, callback/background settings,
trust roots, licenses and the expected DDI resource hashes. The delivered IPA is
24,920,284 bytes, SHA256
b5f9953d7ed4b9d3413ebe36c650ac534173045d4e2349602f239659dada5b63.
It is saved in the user's top-level deliverables directory. USB staging was
attempted after verification, but no USB-connected iPhone was available then.
The new build's physical-device UI remains unverified; build28 device evidence
above does not substitute for build29 acceptance.
