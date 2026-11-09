import XCTest
@testable import LocSign

final class SigningProvisioningViewModelTests: XCTestCase {
    @MainActor
    func testOneClickSigningFailureStopsBeforeUpload() async throws {
        let fixture = try await setup(signerFails: true)
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertNil(fixture.model.outputURL)
        let installs = await fixture.installer.calls
        XCTAssertEqual(installs, 0)
    }

    @MainActor
    func testCancelledInstallerCannotPublishLateSuccess() async throws {
        let fixture = try await setup(delayedInstall: true)
        let task = Task { await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true) }
        await fulfillment(of: [fixture.installer.started], timeout: 2)
        await fixture.model.cancelProvisioning()
        await fixture.installer.release()
        await task.value
        XCTAssertFalse(fixture.model.installSucceeded)
        XCTAssertFalse(fixture.model.isOneClickInstalling)
        XCTAssertNotNil(fixture.model.outputURL)
    }

    @MainActor
    func testOneClickUsesCacheAndInstallsWithoutManualCheckOrProvider() async throws {
        let fixture = try await setup()
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: false)
        XCTAssertNil(fixture.model.error)
        XCTAssertTrue(fixture.model.installSucceeded)
        XCTAssertEqual(fixture.model.outputURL, fixture.signedIPA)
        let requests = await fixture.engine.requests
        let installs = await fixture.installer.calls
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(installs, 1)
    }

    @MainActor
    func testOneClickCacheMissProvisionsThenInstalls() async throws {
        let fixture = try await setup(cache: false)
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true)
        XCTAssertTrue(fixture.model.installSucceeded)
        let requests = await fixture.engine.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.deviceUDID, "SYNTHETIC-UDID")
    }

    @MainActor
    func testOneClickCacheValidationFailureDoesNotRequestOrInstall() async throws {
        let fixture = try await setup(cacheFailure: true)
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true)
        XCTAssertNotNil(fixture.model.error)
        let requests = await fixture.engine.requests
        let installs = await fixture.installer.calls
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(fixture.model.needsAccountSetup)
    }

    @MainActor
    func testOneClickCacheMissRequiresLoginBeforeNewMaterialRequest() async throws {
        let fixture = try await setup(cache: false)
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: false)
        XCTAssertTrue(fixture.model.needsAccountSetup)
        XCTAssertFalse(fixture.model.installSucceeded)
        let requests = await fixture.engine.requests
        let installs = await fixture.installer.calls
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(installs, 0)
    }

    @MainActor
    func testOneClickInstallFailureKeepsSignedFileAndDoesNotRetry() async throws {
        let fixture = try await setup(installFails: true)
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true)
        XCTAssertFalse(fixture.model.installSucceeded)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertEqual(fixture.model.outputURL, fixture.signedIPA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.signedIPA.path))
        let installs = await fixture.installer.calls
        XCTAssertEqual(installs, 1)
    }

    @MainActor
    func testOneClickDuplicateAndCancellationNeverInstallLateMaterial() async throws {
        let fixture = try await setup(delayed: true, cache: false)
        let task = Task { await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true) }
        await fulfillment(of: [fixture.engine.started], timeout: 2)
        await fixture.model.installIPA(using: fixture.engine, account: account, teamID: "TEAM12345", canProvision: true)
        await fixture.model.cancelProvisioning()
        await fixture.engine.release()
        await task.value
        XCTAssertNil(fixture.model.outputURL)
        XCTAssertFalse(fixture.model.isOneClickInstalling)
        let requests = await fixture.engine.requests
        let installs = await fixture.installer.calls
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(installs, 0)
    }

    @MainActor
    func testPersonalIdentifierIsRestoredForSameAppAndTeamAfterRelaunch() async throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        addTeardownBlock { defaults.removePersistentDomain(forName: id); try? FileManager.default.removeItem(at: root) }
        let settings = InstallationSettings(directory: root, defaults: defaults)
        let first = try await setup(settings: settings)
        first.model.usesPersonalBundleID = true
        first.model.personalBundleID = "com.personal.stable"
        await first.model.installIPA(using: first.engine, account: account, teamID: "TEAM12345", canProvision: false)
        XCTAssertTrue(first.model.installSucceeded)
        let second = try await setup(settings: InstallationSettings(directory: root, defaults: defaults))
        await second.model.restoreSigningIdentifier(teamID: "TEAM12345")
        XCTAssertTrue(second.model.usesPersonalBundleID)
        XCTAssertEqual(second.model.personalBundleID, "com.personal.stable")
        await second.model.restoreSigningIdentifier(teamID: "OTHERTEAM")
        XCTAssertFalse(second.model.usesPersonalBundleID)
        XCTAssertTrue(second.model.personalBundleID.isEmpty)
    }

    @MainActor
    func testSigningAutomaticallyAuthenticatesDeviceWithoutManualProbe() async throws {
        let fixture = try await setup()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account,
            teamID: "TEAM12345", providerAccepted: true)
        XCTAssertEqual(fixture.model.verifiedDeviceUDID, "SYNTHETIC-UDID")
        XCTAssertEqual(fixture.model.outputURL, fixture.signedIPA)
        XCTAssertNil(fixture.model.error)
    }

    @MainActor
    func testOnlyExplicitPersonalModeSendsTheSelectedIdentifier() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        fixture.model.personalBundleID = "com.personal.test"
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        var requests = await fixture.engine.requests
        XCTAssertNil(requests.last?.signingBundleID)
        fixture.model.usesPersonalBundleID = true
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        requests = await fixture.engine.requests
        XCTAssertEqual(requests.last?.signingBundleID, "com.personal.test")
    }

    @MainActor
    func testInvalidPersonalIdentifierNeverSendsMaterialRequest() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        fixture.model.usesPersonalBundleID = true
        for invalid in ["", "com.*", "com/escape", ".invalid", "com..invalid"] {
            fixture.model.personalBundleID = invalid
            await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
            let requests = await fixture.engine.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNotNil(fixture.model.error)
        }
    }

    @MainActor
    func testChangingPersonalIdentifierDiscardsOldOutput() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        XCTAssertNotNil(fixture.model.outputURL)
        fixture.model.usesPersonalBundleID = true
        XCTAssertNil(fixture.model.outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.signedIPA.path))
    }

    @MainActor
    func testAccountOutputCleanupDeletesIPAAndClearsExpiryAndSuccessState() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        XCTAssertNotNil(fixture.model.outputURL)
        fixture.model.clearProvisioningOutput()
        XCTAssertNil(fixture.model.outputURL)
        XCTAssertNil(fixture.model.profileExpiry)
        XCTAssertNil(fixture.model.certificateExpiry)
        XCTAssertFalse(fixture.model.installSucceeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.signedIPA.path))
    }
    @MainActor
    func testCachedSigningWorksWithoutProviderConsentAndNeverRequestsNewMaterials() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345",
            providerAccepted: false, useCachedMaterial: true)
        XCTAssertEqual(fixture.model.outputURL, fixture.signedIPA)
        let requests = await fixture.engine.requests
        XCTAssertTrue(requests.isEmpty)
    }
    @MainActor
    func testConsentAndPairedDeviceAreRequiredBeforeAnyMaterialRequest() async throws {
        let fixture = try await setup()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: false)
        let requests = await fixture.engine.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertNil(fixture.model.outputURL)
    }

    @MainActor
    func testTLSDeviceMismatchNeverReachesProvisioningAndVerifiedDeviceUsesExactUDID() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        XCTAssertEqual(fixture.model.verifiedDeviceUDID, "SYNTHETIC-UDID")
        await fixture.probe.changeDevice()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        let requests = await fixture.engine.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNotNil(fixture.model.error)
    }

    @MainActor
    func testMaterialIsSignedBeforeOutputIsPublishedAndInstallSuccessRemainsSeparate() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        let requests = await fixture.engine.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.deviceUDID, "SYNTHETIC-UDID")
        XCTAssertEqual(fixture.model.outputURL, fixture.signedIPA)
        XCTAssertFalse(fixture.model.installSucceeded)
        XCTAssertFalse(fixture.model.isProvisioning)
        XCTAssertNil(fixture.model.error)
    }

    @MainActor
    func testCancelRejectsLateMaterialAndDoesNotPublishOutput() async throws {
        let fixture = try await setup(delayed: true)
        await fixture.model.verifyProvisioningDevice()
        let task = Task { await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true) }
        await fulfillment(of: [fixture.engine.started], timeout: 2)
        await fixture.model.cancelProvisioning()
        await fixture.engine.release()
        await task.value
        XCTAssertNil(fixture.model.outputURL)
        XCTAssertFalse(fixture.model.isProvisioning)
    }

    private let account = ProvisioningAccount(id: UUID(), appleID: "user@example.com", teams: [.init(id: "TEAM12345", name: "Synthetic")])
    @MainActor
    func testRepeatedSubmissionAndImportsAreBlockedWhileProvisioning() async throws {
        let fixture = try await setup(delayed: true)
        await fixture.model.verifyProvisioningDevice()
        let task = Task { await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true) }
        await fulfillment(of: [fixture.engine.started], timeout: 2)
        XCTAssertTrue(fixture.model.isProvisioning)
        XCTAssertFalse(fixture.model.canSign)
        let name = fixture.model.ipaName
        await fixture.model.importFile(fixture.signedIPA, as: .ipa)
        XCTAssertEqual(fixture.model.ipaName, name)
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        let requests = await fixture.engine.requests
        XCTAssertEqual(requests.count, 1)
        await fixture.model.cancelProvisioning()
        await fixture.engine.release()
        await task.value
    }

    @MainActor
    func testChangingHostInvalidatesVerifiedDeviceAndAutomaticallyChecksAgain() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        fixture.model.deviceHost = "127.0.0.2"
        XCTAssertNil(fixture.model.verifiedDeviceUDID)
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        let requests = await fixture.engine.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(fixture.model.verifiedDeviceUDID, "SYNTHETIC-UDID")
    }

    @MainActor
    func testSignerFailureDoesNotPublishOutput() async throws {
        let fixture = try await setup(signerFails: true)
        await fixture.model.verifyProvisioningDevice()
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        XCTAssertNil(fixture.model.outputURL)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertFalse(fixture.model.installSucceeded)
    }
    private struct Fixture {
        let model: SigningViewModel
        let probe: SigningDeviceProbeFixture
        let engine: SigningProvisioningEngineFixture
        let signedIPA: URL
        let installer: OneClickInstallerFixture
    }
    @MainActor
    private func setup(delayed: Bool = false, signerFails: Bool = false, cache: Bool = true,
                       cacheFailure: Bool = false, installFails: Bool = false, delayedInstall: Bool = false,
                       settings: InstallationSettings? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ipa = root.appendingPathComponent("input.ipa")
        let signed = root.appendingPathComponent("signed.ipa")
        try Data("synthetic-ipa".utf8).write(to: ipa)
        try Data("synthetic-signed-ipa".utf8).write(to: signed)
        let probe = SigningDeviceProbeFixture()
        let engine = SigningProvisioningEngineFixture(delayed: delayed, cache: cache, cacheFailure: cacheFailure)
        let installer = OneClickInstallerFixture(fail: installFails, delayed: delayedInstall)
        let model = SigningViewModel(settings: settings, installer: installer, deviceProbe: probe,
            inspectBundleID: { _ in "com.test.app" }, materialSigner: { _, material in
            XCTAssertEqual(material.privateKeyPEM, "synthetic-private-key")
            if signerFails { throw LocSignError.signing("synthetic signing failure") }
            return signed
        })
        model.deviceHost = "127.0.0.1"
        await model.importFile(ipa, as: .ipa)
        await model.importFile(try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist")), as: .pairing)
        return Fixture(model: model, probe: probe, engine: engine, signedIPA: signed, installer: installer)
    }
}

private actor SigningDeviceProbeFixture: PairedDeviceProbing {
    private var udid = "SYNTHETIC-UDID"
    func changeDevice() { udid = "DIFFERENT-UDID" }
    func deviceUDID(host: String, pairingData: Data) async throws -> String { udid }
}
private actor SigningProvisioningEngineFixture: ProvisioningEngine {
    nonisolated let started = XCTestExpectation(description: "Material request entered engine")
    private let delayed: Bool
    private let cache: Bool
    private let cacheFailure: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    var requests: [ProvisioningRequest] = []
    init(delayed: Bool, cache: Bool, cacheFailure: Bool) {
        self.delayed = delayed; self.cache = cache; self.cacheFailure = cacheFailure
    }
    func release() { continuation?.resume(); continuation = nil }
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount { throw ProvisioningError.invalidAccount }
    func restoreAccount() async throws -> ProvisioningAccount? { nil }
    func logout(account: String) async throws {}
    func cancel() async {}
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        requests.append(request)
        if delayed {
            await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() }
        }
        return ProvisioningMaterial(privateKeyPEM: "synthetic-private-key", profileData: Data("synthetic-profile".utf8),
            certificateExpiry: Date().addingTimeInterval(3600), profileExpiry: Date().addingTimeInterval(3600))
    }
    func cachedMaterial(request: ProvisioningRequest) async throws -> ProvisioningMaterial? {
        if cacheFailure { throw ProfileValidationError.cms }
        guard cache else { return nil }
        return ProvisioningMaterial(privateKeyPEM: "synthetic-private-key", profileData: Data("synthetic-profile".utf8),
            certificateExpiry: .distantFuture, profileExpiry: .distantFuture)
    }
}

private actor OneClickInstallerFixture: IPAInstalling {
    nonisolated let started = XCTestExpectation(description: "Installation entered")
    let fail: Bool
    let delayed: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(fail: Bool, delayed: Bool) { self.fail = fail; self.delayed = delayed }
    func release() { continuation?.resume(); continuation = nil }
    func install(ipaURL: URL, host: String, pairingData: Data, progress: @Sendable (Double) async -> Void) async throws {
        calls += 1
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipaURL.path))
        XCTAssertEqual(host, "127.0.0.1")
        _ = try PairingRecord(data: pairingData)
        if delayed { await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() } }
        await progress(1)
        if fail { throw LocSignError.install("synthetic install failure") }
    }
}
