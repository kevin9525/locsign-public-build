import XCTest
@testable import LocSign

final class SigningProvisioningViewModelTests: XCTestCase {
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
    func testChangingHostInvalidatesVerifiedDevice() async throws {
        let fixture = try await setup()
        await fixture.model.verifyProvisioningDevice()
        fixture.model.deviceHost = "127.0.0.2"
        XCTAssertNil(fixture.model.verifiedDeviceUDID)
        await fixture.model.provisionAndSign(using: fixture.engine, account: account, teamID: "TEAM12345", providerAccepted: true)
        let requests = await fixture.engine.requests
        XCTAssertTrue(requests.isEmpty)
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
    }
    @MainActor
    private func setup(delayed: Bool = false, signerFails: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ipa = root.appendingPathComponent("input.ipa")
        let signed = root.appendingPathComponent("signed.ipa")
        try Data("synthetic-ipa".utf8).write(to: ipa)
        try Data("synthetic-signed-ipa".utf8).write(to: signed)
        let probe = SigningDeviceProbeFixture()
        let engine = SigningProvisioningEngineFixture(delayed: delayed)
        let model = SigningViewModel(deviceProbe: probe, materialSigner: { _, material in
            XCTAssertEqual(material.privateKeyPEM, "synthetic-private-key")
            if signerFails { throw LocSignError.signing("synthetic signing failure") }
            return signed
        })
        model.deviceHost = "127.0.0.1"
        await model.importFile(ipa, as: .ipa)
        await model.importFile(try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist")), as: .pairing)
        return Fixture(model: model, probe: probe, engine: engine, signedIPA: signed)
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
    private var continuation: CheckedContinuation<Void, Never>?
    var requests: [ProvisioningRequest] = []
    init(delayed: Bool) { self.delayed = delayed }
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
        ProvisioningMaterial(privateKeyPEM: "synthetic-private-key", profileData: Data("synthetic-profile".utf8),
            certificateExpiry: .distantFuture, profileExpiry: .distantFuture)
    }
}
