# Remember the location connection mode

The user confirmed that 0.4.4's no-Wi-Fi apply succeeded, and that after restoring, Apple's Maps location arrow placed the blue dot at the real position. Some other Apps still displayed the old address. This establishes that the observed restore worked; it does not establish when each other App refreshes its cached or selected address.

The next bounded improvement continues the approved fixed-point location UI: choose direct connection or the existing no-Wi-Fi assistance once, remember that preference, and route both main apply/restore buttons through it. Default to direct on an upgrade without a saved choice, so an upgrade alone never causes a cellular-data toggle. Do not infer that a remembered mode means location is active. A pending cellular recovery must be resolved before changing modes. The existing shortcut names and actual device connection pipeline remain in use.

A successful restore displays an explanation about refreshing other Apps' positions and manually selected addresses. Clear this notice on the next device request, a settings change or a session failure. Do not claim that LocSign reads GPS, flushes another App's cache, or verified the real position. No additional location permission or background positioning is introduced.

Behavioral tests cover mode persistence and routing after relaunch, returning to direct mode without shortcuts, safe handling of an absent/unknown preference, failed assisted readiness preventing restore, notice lifecycle after success/failure, and protecting the mode while another device operation or cellular recovery is pending. Tests were written before production edits. Windows has neither Swift nor Xcode; an XCTest red baseline could not be executed locally.

## Verification and delivery

The independent review found no critical or important issues. [CI run 44030290318](https://github.com/kevin9525/locsign-public-build/actions/runs/44030290318) completed successfully for source `9cb93ebab007fc1cb48f98cd656a2b5e53ecd9ea`. Its downloaded log confirms all 405 XCTest cases passed, including the six new ViewModel cases, alongside 16 native tests and 8 packaging tests. The simulator and unsigned device builds succeeded.

On 2026-11-19, artifact `14306735320` was downloaded and verified locally. `LocSign-0.4.5-build24-unsigned.ipa` is 24,798,052 bytes with SHA-256 `45eafee431275b610af127a6c2e68dfae644ee0dfaddafe1f5bac1b36e525f9b`. Checks passed for ZIP CRC, version/build, original bundle identity, arm64 executable, unsigned packaging, callback scheme, background processing declaration, certificate/license resources and all three developer-image resource hashes. The IPA, verification JSON and Chinese instructions were saved in the user's designated deliverables directory.

The 0.4.4 device feedback above supports the existing underlying apply/restore path. This 0.4.5 interface and preference change has not yet been installed or verified on the phone. Use the original signing identity for an in-place update, select the desired mode once, and reuse the existing two shortcuts.
