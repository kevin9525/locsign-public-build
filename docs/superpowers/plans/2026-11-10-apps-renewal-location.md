# App management, renewal and location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for inline implementation; independent location research follows dispatching-parallel-agents. Track steps below.

**Goal:** Retain installed Apps for renewal and expose functioning fixed-point device location.

**Architecture:** A shared account/settings owner feeds installation, a protected App library and one renewal queue. Device browsing is read-only installation_proxy; location is a separate pinned FFI adapter. Existing validated installation and signing remain the pipeline.

**Tech Stack:** SwiftUI, Foundation, BackgroundTasks, UserNotifications, MapKit, existing Zsign/XKit; pinned MIT idevice where compatible.

**Spec:** `docs/superpowers/specs/2026-11-10-apps-renewal-location.md`

## Global Constraints

- iOS 17 minimum; target device iPhone 15 Pro Max / iOS 18.7.8.
- macos-15-intel CI only; no credentials, pairing files or private history in public builds.
- No automatic certificate revocation or profile deletion.
- Original profile/device/team/key/CMS validation remains required.
- Background is best effort, with foreground catch-up and notifications.
- Fixed-point location only; no routes or joystick.

## Review Focus

- A failed upload must retain previous confirmed expiry and the original IPA.
- A different signed identifier or connected device must never silently replace the recorded App.
- A crash while saving metadata must leave either the previous committed record or a recoverable pending attempt.
- A repeated old Apple profile must not be reported as successful renewal.
- Background expiration or location disconnect must not cause overlapping device operations or a false success.

### Task 1: Profile freshness contract

**Files:** ProvisioningTypes.swift, ProvisioningEngine.swift, ProvisioningBackendLive.swift, DeveloperServicesProvisioner.swift; corresponding XCTest files.

**Interfaces:** `ProvisioningRequest.minimumProfileExpiry: Date? = nil`; `DeveloperServicesProvisioner.provision(..., minimumProfileExpiry: Date? = nil, confirmRevocation: ...)`.

- [ ] Add tests showing cached material below/equal to a minimum is a cache miss, backend cannot return an insufficiently fresh profile, remote list skips an old matching profile, 409 recovery cannot return an old profile, and nil preserves reuse.
  ```swift
  request.minimumProfileExpiry = previous.profileExpiry
  let cached = try await engine.cachedMaterial(request: request)
  XCTAssertNil(cached)
  ```
- [ ] Exercise tests in macOS CI; expected old implementation rejects the new freshness contract. Windows cannot execute XCTest.
- [ ] Validate authenticated profile expiry strictly exceeds minimum in cache, backend and provisioner; preserve active material when a new response fails.
  ```swift
  if let minimumProfileExpiry, validated.expiry <= minimumProfileExpiry {
      throw ProvisioningError.materialInvalid("描述文件有效期未延长，请稍后重试")
  }
  ```
- [ ] Run full XCTest suite and commit verified implementation.

### Task 2: Protected managed App library and install capture

**Files:** new Features/Apps/ManagedAppLibrary.swift, AppRenewalPolicy.swift; SigningViewModel.swift; ManagedAppLibraryTests.swift.

**Interfaces:** `ManagedApp` Codable/Identifiable with immutable identity and optional pending install; `ManagedAppLibrary.prepare(...) async throws -> UUID`, `confirmInstallation(id:) throws`, `fail(id:message:) throws`, `sourceURL(for:) throws`, `remove(id:) throws`. Settings and account owner injected, not duplicated.

- [ ] Tests first: real file copies survive source deletion and reopen; failed/pending install retains prior expiry; failed metadata write never deletes previous IPA; remove only owned IPA; changed account/team/device remains separate; corrupted metadata is surfaced and not overwritten.
  ```swift
  let pending = try await library.prepare(source: ipa, identity: identity, material: material)
  XCTAssertNil(library.apps.first?.installedAt)
  try library.confirmInstallation(id: pending)
  XCTAssertEqual(library.apps.first?.profileExpiry, material.profileExpiry)
  ```
- [ ] Implement atomic manifest writes and unique immutable IPA filenames. Create source before metadata commit; clean unreferenced candidate on failure. Preserve previous record until installation confirmation.
- [ ] Integrate prepare before upload and confirm after successful upload. A record failure following device success reports installation success plus actionable catalog failure.
- [ ] Add a shared root services owner and inject the same AppleIDProvisioningModel into SigningView and App management.
- [ ] Run persistence/installation tests and commit.

### Task 3: Device App browser and management screen

**Files:** new InstalledAppBrowser.swift, AppsView.swift; InstallationProxyClient.swift; InstalledAppBrowserTests.swift.

**Interfaces:** `InstalledApp: Identifiable, Sendable`; `InstalledAppListing.listApps(host:pairingData:) async throws -> InstalledAppList` where result includes verified deviceUDID. Browser owns its lockdown/heartbeat/service lifecycle.

- [ ] Test paginated CurrentList merging, duplicate bundle IDs, malformed rows/counters, explicit Error, finite maximum rows/pages and cancellation cleanup.
  ```swift
  XCTAssertEqual(try InstalledAppPage.parse(response).apps.map(\.id), ["com.example.app"])
  ```
- [ ] Implement Browse User Apps with selected return fields, start/check/stop heartbeat and close on every exit.
- [ ] Display managed status, expiry, manual renew, auto toggle, retry/last error and clear local data. Show unmanaged installed Apps with original-IPA guidance. Bind listing to verified device, do not mark missing Apps from a failed scan.
- [ ] Run browser tests and commit.

### Task 4: Renewal queue and OS scheduling

**Files:** new AppRenewalCoordinator.swift, RenewalBackgroundService.swift; LocSignApp.swift, Info.plist, project.yml; AppRenewalPolicyTests.swift and renewal integration tests.

**Interfaces:** `AppRenewalPolicy.due(_ app: ManagedApp, now: Date, runningBundleID: String?) -> Bool`; coordinator `runDue() async`, `renew(id:) async`, `cancel()`, sharing InstallationSettings lock/account.

- [ ] Test 48-hour boundary, six-hour retry, pending attempt exclusion, global/per-app opt out, missing source, device mismatch and self-app automatic exclusion. Test failed installation does not advance expiry; cancellation does not start next app.
  ```swift
  XCTAssertFalse(AppRenewalPolicy.due(app, now: retryDate.addingTimeInterval(-1), runningBundleID: nil))
  ```
- [ ] Persist next attempt before network work; reuse signing pipeline with exact recorded account/team/bundle/device and minimum expiry `max(now + 48h, previousProfileExpiry)`.
- [ ] Register BGProcessingTask at launch, require network, schedule next eligible time, set expiration handler to cancel; defer when protected data unavailable. Foreground runs same queue. Request notification permission from user-facing settings and use generic failure notifications.
- [ ] Recover pending self update only if running bundle and embedded validated metadata prove the proposed profile is actually installed. Present manual self-update termination notice.
- [ ] Run queue tests and commit.

### Task 5: Native fixed-point location

**Files:** new Engines/Location/*, Features/Location/*, Vendor/idevice integration, .ci dependency preparation, project.yml; location validation tests.

**Interfaces:** `LocationCoordinate(latitude:longitude:) throws`; `DeviceLocationControlling.set(_:host:pairingData:) async throws`, `clear(host:pairingData:) async throws`; location ViewModel sharing InstallationSettings.

- [ ] Verify pinned v0.1.68 FFI handles, MIT license, library slice architectures and OpenSSL conflicts before build configuration. Preserve investigation evidence locally.
- [ ] Test finite coordinate ranges, failure leaves unknown/previous state, restore must receive success, cancellation cannot free handles under active FFI work.
  ```swift
  XCTAssertThrowsError(try LocationCoordinate(latitude: .nan, longitude: 0))
  XCTAssertThrowsError(try LocationCoordinate(latitude: 0, longitude: 181))
  ```
- [ ] Own C resources on a serial worker; connect provider → CoreDevice proxy → tunnel adapter → RSD → DVT location. Verify/mount compatible personalized DDI with checksum-pinned resources or surface explicit preparation instructions when device prerequisites are absent.
- [ ] Add map/search/manual coordinate UI, apply/restore and honest device state; persist selected point without claiming active simulation across launch.
- [ ] Build both simulator and arm64 device; commit validated integration.

### Task 6: Review and delivery

- [ ] Record user's 0.3.2 installation success, update version/release notes and device acceptance procedure.
- [ ] Fresh branch review, fix concrete issues, run `python -m unittest discover -s Tests/BuildTools -v`, full macOS XCTest, simulator/device build and IPA packing.
- [ ] Sync only changed safe sources/tests/docs to public mirror, preserve three fixture redaction differences, push authorized branches.
- [ ] Download CI artifact; validate ZIP, Info.plist version, resources and SHA256. Deliver IPA and remaining true-device checks without claiming background timing or GPS acceptance was proven by simulator tests.
