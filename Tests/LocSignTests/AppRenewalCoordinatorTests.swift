import XCTest
@testable import LocSign

@MainActor
final class AppRenewalCoordinatorTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testWrongAccountTeamOrDeviceStopsBeforeMaterialSigningAndUpload() async throws {
        let cases = [
            (appleID: "other@example.com", team: "TEAM", device: "DEVICE"),
            (appleID: "user@example.com", team: "OTHER", device: "DEVICE"),
            (appleID: "user@example.com", team: "TEAM", device: "OTHER-DEVICE")
        ]
        for mismatch in cases {
            let fixture = try await setup(appleID: mismatch.appleID, team: mismatch.team, device: mismatch.device)
            let before = try XCTUnwrap(fixture.library.apps.first)
            let result = await fixture.coordinator.runDue()
            XCTAssertFalse(result)
            XCTAssertTrue(fixture.signer.inputs.isEmpty)
            let requests = await fixture.engine.cachedRequests
            let remote = await fixture.engine.provisionRequests
            let uploads = await fixture.installer.uploads
            XCTAssertTrue(requests.isEmpty)
            XCTAssertTrue(remote.isEmpty)
            XCTAssertTrue(uploads.isEmpty)
            let after = try XCTUnwrap(fixture.library.apps.first)
            XCTAssertEqual(after.identity, before.identity)
            XCTAssertEqual(after.profileExpiry, before.profileExpiry)
            XCTAssertNotNil(after.lastError)
            XCTAssertNil(fixture.settings.operationID)
        }
    }

    func testFreshProfileIsConfirmedOnlyAfterInstallerSucceeds() async throws {
        let fixture = try await setup(delayedInstall: true)
        let original = try XCTUnwrap(fixture.library.apps.first)
        let task = Task { await fixture.coordinator.runDue() }
        await fulfillment(of: [fixture.installer.started], timeout: 5)

        let pending = try XCTUnwrap(fixture.library.apps.first)
        XCTAssertEqual(pending.profileExpiry, original.profileExpiry)
        XCTAssertEqual(pending.installedAt, original.installedAt)
        XCTAssertEqual(pending.pending?.profileExpiry, date.addingTimeInterval(7 * 86400))
        XCTAssertEqual(pending.nextAttempt, date.addingTimeInterval(6 * 3600))
        XCTAssertEqual(ManagedAppLibrary(directory: fixture.folder).apps.first?.profileExpiry, original.profileExpiry)
        let requests = await fixture.engine.cachedRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.minimumProfileExpiry, date.addingTimeInterval(48 * 3600))
        XCTAssertEqual(request.signingBundleID, original.identity.signingBundleID)
        XCTAssertEqual(request.teamID, original.identity.teamID)
        XCTAssertEqual(request.deviceUDID, original.identity.deviceUDID)
        XCTAssertEqual(fixture.signer.inputs.first?.bytes, Data("original IPA 0".utf8))

        await fixture.installer.release()
        let result = await task.value
        XCTAssertTrue(result)
        let saved = try XCTUnwrap(ManagedAppLibrary(directory: fixture.folder).apps.first)
        XCTAssertEqual(saved.profileExpiry, date.addingTimeInterval(7 * 86400))
        XCTAssertEqual(saved.installedAt, date)
        XCTAssertNil(saved.pending)
        XCTAssertNil(saved.nextAttempt)
        XCTAssertNil(saved.lastError)
        XCTAssertEqual(try Data(contentsOf: fixture.library.sourceURL(for: saved.id)), Data("original IPA 0".utf8))
        XCTAssertNil(fixture.settings.operationID)
        XCTAssertFalse(fixture.coordinator.isRunning)
    }

    func testInstallationFailurePreservesConfirmedExpiryAndOriginalSourceAcrossRelaunch() async throws {
        let fixture = try await setup(installFails: true)
        let original = try XCTUnwrap(fixture.library.apps.first)
        let source = try fixture.library.sourceURL(for: original.id)
        let result = await fixture.coordinator.runDue()
        XCTAssertFalse(result)
        let reopened = ManagedAppLibrary(directory: fixture.folder)
        let saved = try XCTUnwrap(reopened.apps.first)
        XCTAssertEqual(saved.profileExpiry, original.profileExpiry)
        XCTAssertEqual(saved.certificateExpiry, original.certificateExpiry)
        XCTAssertEqual(saved.installedAt, original.installedAt)
        XCTAssertEqual(try reopened.sourceURL(for: saved.id), source)
        XCTAssertEqual(try Data(contentsOf: source), Data("original IPA 0".utf8))
        XCTAssertNil(saved.pending)
        XCTAssertNotNil(saved.lastError)
        XCTAssertEqual(saved.nextAttempt, date.addingTimeInterval(6 * 3600))
        XCTAssertNil(fixture.settings.operationID)
    }

    func testGlobalAndPerAppOptOutPreventAutomaticAttempts() async throws {
        let fixture = try await setup()
        let id = try XCTUnwrap(fixture.library.apps.first?.id)
        fixture.coordinator.enabled = false
        let disabled = await fixture.coordinator.runDue()
        XCTAssertTrue(disabled)
        fixture.coordinator.enabled = true
        try fixture.library.setAutoRenew(id: id, enabled: false)
        let optedOut = await fixture.coordinator.runDue()
        XCTAssertTrue(optedOut)
        let uploads = await fixture.installer.uploads
        let requests = await fixture.engine.cachedRequests
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(fixture.signer.inputs.isEmpty)
        XCTAssertNil(fixture.library.apps.first?.lastAttempt)

        try fixture.library.setAutoRenew(id: id, enabled: true)
        let enabled = await fixture.coordinator.runDue()
        XCTAssertTrue(enabled)
        XCTAssertEqual(fixture.library.apps.first?.profileExpiry, date.addingTimeInterval(7 * 86400))
    }

    func testFailedAutomaticAttemptIsSuppressedForSixHours() async throws {
        let fixture = try await setup(installFails: true)
        let first = await fixture.coordinator.runDue()
        XCTAssertFalse(first)
        fixture.clock.date = date.addingTimeInterval(6 * 3600 - 1)
        let suppressed = await fixture.coordinator.runDue()
        XCTAssertTrue(suppressed)
        let firstUploads = await fixture.installer.uploads
        XCTAssertEqual(firstUploads.count, 1)
        XCTAssertEqual(fixture.library.apps.first?.lastAttempt, date)

        fixture.clock.date = date.addingTimeInterval(6 * 3600)
        let retried = await fixture.coordinator.runDue()
        XCTAssertFalse(retried)
        let retriedUploads = await fixture.installer.uploads
        XCTAssertEqual(retriedUploads.count, 2)
        XCTAssertEqual(fixture.library.apps.first?.lastAttempt, date.addingTimeInterval(6 * 3600))
        XCTAssertEqual(fixture.library.apps.first?.nextAttempt, date.addingTimeInterval(12 * 3600))
    }

    func testAutomaticRenewalDeclinesCertificateRevocationWithoutPromptingOrSigning() async throws {
        let fixture = try await setup(mode: .revocation)
        let previous = fixture.library.apps.first?.profileExpiry
        let result = await fixture.coordinator.runDue()
        XCTAssertFalse(result)
        let approvals = await fixture.engine.revocationResponses
        let remote = await fixture.engine.provisionRequests
        let uploads = await fixture.installer.uploads
        XCTAssertEqual(approvals, [false])
        XCTAssertEqual(remote.count, 1)
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(fixture.signer.inputs.isEmpty)
        XCTAssertTrue(fixture.account.revocations.isEmpty)
        XCTAssertFalse(fixture.account.awaitingCode)
        XCTAssertEqual(fixture.library.apps.first?.profileExpiry, previous)
        XCTAssertNotNil(fixture.library.apps.first?.lastError)
    }

    func testSharedDeviceOperationLockRejectsOverlapAndIsReleasedAfterRenewal() async throws {
        let fixture = try await setup(delayedInstall: true)
        let occupied = try XCTUnwrap(fixture.settings.beginOperation())
        let blocked = await fixture.coordinator.runDue()
        XCTAssertFalse(blocked)
        XCTAssertNil(fixture.library.apps.first?.lastAttempt)
        XCTAssertEqual(fixture.settings.operationID, occupied)
        fixture.settings.endOperation(occupied)

        let task = Task { await fixture.coordinator.runDue() }
        await fulfillment(of: [fixture.installer.started], timeout: 5)
        let active = try XCTUnwrap(fixture.settings.operationID)
        XCTAssertNil(fixture.settings.beginOperation())
        let competing = fixture.makeCoordinator()
        let overlap = await competing.renew(id: try XCTUnwrap(fixture.library.apps.first?.id))
        XCTAssertFalse(overlap)
        XCTAssertEqual(fixture.settings.operationID, active)
        let uploads = await fixture.installer.uploads
        XCTAssertEqual(uploads.count, 1)
        await fixture.installer.release()
        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertNil(fixture.settings.operationID)
        let next = try XCTUnwrap(fixture.settings.beginOperation())
        fixture.settings.endOperation(next)
    }

    func testCancellationPreservesExpiryAndDoesNotStartNextApp() async throws {
        let fixture = try await setup(appCount: 2, delayedInstall: true)
        let original = fixture.library.apps
        let task = Task { await fixture.coordinator.runDue() }
        await fulfillment(of: [fixture.installer.started], timeout: 5)
        fixture.coordinator.cancel()
        await fixture.installer.release()
        let result = await task.value
        XCTAssertFalse(result)
        let uploads = await fixture.installer.uploads
        let requests = await fixture.engine.cachedRequests
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.signingBundleID, original[0].identity.signingBundleID)
        XCTAssertEqual(fixture.signer.inputs.count, 1)
        let first = try XCTUnwrap(fixture.library.apps.first { $0.id == original[0].id })
        let next = try XCTUnwrap(fixture.library.apps.first { $0.id == original[1].id })
        XCTAssertEqual(first.profileExpiry, original[0].profileExpiry)
        XCTAssertEqual(next.profileExpiry, original[1].profileExpiry)
        XCTAssertNil(next.lastAttempt)
        XCTAssertNil(next.pending)
        XCTAssertNil(fixture.settings.operationID)
        XCTAssertFalse(fixture.coordinator.isRunning)
    }

    func testBackendReturningInsufficientFreshnessCannotReachSignerOrInstaller() async throws {
        let fixture = try await setup(profileLifetime: 48 * 3600)
        let original = fixture.library.apps.first?.profileExpiry
        let result = await fixture.coordinator.runDue()
        XCTAssertFalse(result)
        XCTAssertTrue(fixture.signer.inputs.isEmpty)
        let uploads = await fixture.installer.uploads
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(fixture.library.apps.first?.profileExpiry, original)
        XCTAssertNotNil(fixture.library.apps.first?.lastError)
    }

    func testManualSelfReplacementRemainsPendingUntilSubsequentLaunchVerification() async throws {
        let fixture = try await setup(runningBundleID: "org.example.personal0")
        let original = try XCTUnwrap(fixture.library.apps.first)
        let skipped = await fixture.coordinator.runDue()
        XCTAssertTrue(skipped)
        XCTAssertNil(fixture.library.apps.first?.lastAttempt)

        let result = await fixture.coordinator.renew(id: original.id)
        XCTAssertTrue(result)
        let saved = try XCTUnwrap(ManagedAppLibrary(directory: fixture.folder).apps.first)
        XCTAssertEqual(saved.profileExpiry, original.profileExpiry)
        XCTAssertEqual(saved.installedAt, original.installedAt)
        XCTAssertEqual(saved.pending?.profileExpiry, date.addingTimeInterval(7 * 86400))
        XCTAssertEqual(try Data(contentsOf: fixture.library.sourceURL(for: saved.id)), Data("original IPA 0".utf8))
    }

    func testAppOptedOutWhileQueueIsRunningIsNotRenewed() async throws {
        let fixture = try await setup(appCount: 2, delayedInstall: true)
        let second = try XCTUnwrap(fixture.library.apps.last)
        let task = Task { await fixture.coordinator.runDue() }
        await fulfillment(of: [fixture.installer.started], timeout: 5)
        try fixture.library.setAutoRenew(id: second.id, enabled: false)
        await fixture.installer.release()
        let result = await task.value
        XCTAssertTrue(result)
        let uploads = await fixture.installer.uploads
        XCTAssertEqual(uploads.count, 1)
        let saved = try XCTUnwrap(fixture.library.apps.first { $0.id == second.id })
        XCTAssertFalse(saved.autoRenew)
        XCTAssertNil(saved.lastAttempt)
        XCTAssertEqual(saved.profileExpiry, second.profileExpiry)
    }

    @MainActor
    private struct Fixture {
        let coordinator: AppRenewalCoordinator
        let settings: InstallationSettings
        let library: ManagedAppLibrary
        let folder: URL
        let account: AppleIDProvisioningModel
        let engine: RenewalEngineFixture
        let probe: RenewalDeviceFixture
        let installer: RenewalInstallerFixture
        let signer: RenewalSignerFixture
        let clock: RenewalClockFixture
        let runningBundleID: String

        func makeCoordinator() -> AppRenewalCoordinator {
            AppRenewalCoordinator(settings: settings, library: library, account: account,
                installer: installer, probe: probe, runningBundleID: runningBundleID, now: { clock.date },
                inspect: { _ in .init(bundleID: "org.example.original", name: "Original") }, sign: signer.sign)
        }
    }

    private func setup(appleID: String = "user@example.com", team: String = "TEAM", device: String = "DEVICE",
                       appCount: Int = 1, delayedInstall: Bool = false, installFails: Bool = false,
                       mode: RenewalEngineFixture.Mode = .cached, profileLifetime: TimeInterval = 7 * 86400,
                       runningBundleID: String = "org.example.locsign") async throws -> Fixture {
        let suite = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = InstallationSettings(directory: root.appendingPathComponent("Installation"), defaults: defaults)
        settings.updateHost("127.0.0.1")
        let pairingURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist"))
        try settings.savePairing(data: Data(contentsOf: pairingURL), name: "synthetic.plist")
        let folder = root.appendingPathComponent("Library")
        let library = ManagedAppLibrary(directory: folder)
        for index in 0..<appCount {
            let source = root.appendingPathComponent("source-\(index).ipa")
            try Data("original IPA \(index)".utf8).write(to: source)
            let identity = ManagedApp.Identity(appleID: "user@example.com", teamID: "TEAM", deviceUDID: "DEVICE",
                originalBundleID: "org.example.original", signingBundleID: "org.example.personal\(index)")
            let old = ProvisioningMaterial(privateKeyPEM: "synthetic-key", profileData: Data("old-profile".utf8),
                certificateExpiry: date.addingTimeInterval(30 * 86400), profileExpiry: date.addingTimeInterval(Double(index + 1) * 3600),
                signingBundleID: identity.signingBundleID)
            let id = try await library.prepare(source: source, name: "App \(index)", identity: identity, material: old)
            try library.confirmInstallation(id: id, now: date.addingTimeInterval(-86400))
            try FileManager.default.removeItem(at: source)
        }
        let restored = ProvisioningAccount(id: UUID(), appleID: appleID, teams: [.init(id: team, name: "Synthetic")])
        let engine = RenewalEngineFixture(account: restored, mode: mode,
            profileExpiry: date.addingTimeInterval(profileLifetime), certificateExpiry: date.addingTimeInterval(30 * 86400))
        let account = AppleIDProvisioningModel(settings: settings) { _ in engine }
        account.providerAccepted = true
        let probe = RenewalDeviceFixture(device: device)
        let installer = RenewalInstallerFixture(delayed: delayedInstall, fail: installFails)
        let signer = RenewalSignerFixture(directory: root)
        let clock = RenewalClockFixture(date: date)
        let coordinator = AppRenewalCoordinator(settings: settings, library: library, account: account,
            installer: installer, probe: probe, runningBundleID: runningBundleID, now: { clock.date },
            inspect: { _ in .init(bundleID: "org.example.original", name: "Original") }, sign: signer.sign)
        return Fixture(coordinator: coordinator, settings: settings, library: library, folder: folder, account: account,
            engine: engine, probe: probe, installer: installer, signer: signer, clock: clock, runningBundleID: runningBundleID)
    }
}

@MainActor
private final class RenewalClockFixture {
    var date: Date
    init(date: Date) { self.date = date }
}

@MainActor
private final class RenewalSignerFixture {
    struct Input { let bytes: Data; let material: ProvisioningMaterial }
    private(set) var inputs: [Input] = []
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func sign(_ source: URL, _ material: ProvisioningMaterial) async throws -> URL {
        inputs.append(.init(bytes: try Data(contentsOf: source), material: material))
        let output = directory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data("signed IPA".utf8).write(to: output)
        return output
    }
}

private actor RenewalDeviceFixture: PairedDeviceProbing {
    let device: String
    init(device: String) { self.device = device }
    func deviceUDID(host: String, pairingData: Data) async throws -> String {
        _ = try PairingRecord(data: pairingData)
        return device
    }
}

private actor RenewalEngineFixture: ProvisioningEngine {
    enum Mode: Sendable, Equatable { case cached, revocation }
    let account: ProvisioningAccount
    let mode: Mode
    let profileExpiry: Date
    let certificateExpiry: Date
    private(set) var cachedRequests: [ProvisioningRequest] = []
    private(set) var provisionRequests: [ProvisioningRequest] = []
    private(set) var revocationResponses: [Bool] = []
    init(account: ProvisioningAccount, mode: Mode, profileExpiry: Date, certificateExpiry: Date) {
        self.account = account; self.mode = mode; self.profileExpiry = profileExpiry; self.certificateExpiry = certificateExpiry
    }
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount { account }
    func restoreAccount() async throws -> ProvisioningAccount? { account }
    func restoreSigningAccount() async throws -> ProvisioningAccount? { account }
    func cancel() async {}
    func logout(account: String) async throws {}
    func cachedMaterial(request: ProvisioningRequest) async throws -> ProvisioningMaterial? {
        cachedRequests.append(request)
        guard mode == .cached else { return nil }
        return .init(privateKeyPEM: "synthetic-key", profileData: Data("renewed-profile".utf8),
            certificateExpiry: certificateExpiry, profileExpiry: profileExpiry, signingBundleID: request.signingBundleID)
    }
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        provisionRequests.append(request)
        let confirmed = await confirmRevocation([.init(id: "certificate", serialNumber: "01", name: "Synthetic", expiry: certificateExpiry)])
        revocationResponses.append(confirmed)
        guard confirmed else { throw ProvisioningError.revocationDeclined }
        return .init(privateKeyPEM: "synthetic-key", profileData: Data("renewed-profile".utf8),
            certificateExpiry: certificateExpiry, profileExpiry: profileExpiry, signingBundleID: request.signingBundleID)
    }
}

private actor RenewalInstallerFixture: IPAInstalling {
    nonisolated let started = XCTestExpectation(description: "Renewal installer entered")
    let delayed: Bool
    let fail: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var uploads: [Data] = []
    init(delayed: Bool, fail: Bool) { self.delayed = delayed; self.fail = fail }
    func release() { continuation?.resume(); continuation = nil }
    func install(ipaURL: URL, host: String, pairingData: Data, progress: @Sendable (Double) async -> Void) async throws {
        uploads.append(try Data(contentsOf: ipaURL))
        _ = try PairingRecord(data: pairingData)
        if delayed && uploads.count == 1 {
            await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() }
        }
        if fail { throw LocSignError.install("Synthetic upload failure") }
        await progress(1)
    }
}
