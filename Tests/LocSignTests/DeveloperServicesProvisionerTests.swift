import XCTest
@testable import LocSign

final class DeveloperServicesProvisionerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingIssuanceContentRecoversMatchingCertificateWithoutResubmittingCSR() async throws {
        let fixture = try setup(cached: false)
        await fixture.gateway.setMissingIssuanceContent()
        let material = try await run(fixture)
        XCTAssertEqual(material.profileData, try data("profile-valid", "mobileprovision"))
        let saved = try await fixture.store.loadPending()
        XCTAssertEqual(saved?.certificate?.id, "cert")
        let mutations = await fixture.gateway.mutations
        XCTAssertEqual(mutations, ["certificate"])
    }

    func testRecoversIssuedCertificateAfterLostResponseUsingDurablePendingKey() async throws {
        let fixture = try setup(cached: true)
        let loaded = try await fixture.store.loadPending()
        var pending = try XCTUnwrap(loaded)
        pending.certificate = nil
        try await fixture.store.savePending(pending)
        _ = try await run(fixture)
        let mutations = await fixture.gateway.mutations
        XCTAssertEqual(mutations, [])
        let recovered = try await fixture.store.loadPending()
        XCTAssertEqual(recovered?.certificate?.id, "cert")
    }

    func testReusesDeviceExactBundleCertificateAndAuthenticatedProfileWithoutMutation() async throws {
        let fixture = try setup(cached: true)
        let result = try await run(fixture)
        XCTAssertEqual(result.profileData, try data("profile-valid", "mobileprovision"))
        XCTAssertEqual(Data(result.privateKeyPEM.utf8), try data("test-key", "pem"))
        let mutations = await fixture.gateway.mutations
        XCTAssertEqual(mutations, [])
    }

    func testRegistersOnlyExactDeviceAndBundleAndSavesKeyBeforeCSR() async throws {
        let fixture = try setup(cached: false, missingDevice: true, missingBundle: true, missingProfile: true)
        _ = try await run(fixture)
        let mutations = await fixture.gateway.mutations
        XCTAssertEqual(mutations, ["device:SYNTHETIC-UDID", "bundle:com.test.app", "certificate", "profile:bundle:cert:device"])
        let pending = await fixture.store.pending
        XCTAssertEqual(pending?.certificate?.id, "cert")
        XCTAssertEqual(pending?.privateKeyPEM, try data("test-key", "pem"))
    }

    func testMissingOrExpiredLocalCertificateIsNotReusedAndProfileFailureRetainsIssuedKey() async throws {
        let fixture = try setup(cached: false, missingProfile: true, failProfile: true)
        do { _ = try await run(fixture); XCTFail("Profile failure ignored") }
        catch { XCTAssertEqual(error as? DeveloperServicesError, .rejected(503)) }
        let pending = await fixture.store.pending
        XCTAssertEqual(pending?.certificate?.id, "cert")
        XCTAssertEqual(pending?.privateKeyPEM, try data("test-key", "pem"))
        let mutations = await fixture.gateway.mutations
        XCTAssertTrue(mutations.contains("certificate"))
    }

    func testFailedPendingKeyWriteNeverSendsCSR() async throws {
        let fixture = try setup(cached: false)
        await fixture.store.setFailWrites()
        do { _ = try await run(fixture); XCTFail("Keychain failure ignored") }
        catch {}
        let mutations = await fixture.gateway.mutations
        XCTAssertFalse(mutations.contains("certificate"))
    }

    func testExpiredRemoteCertificateRequiresNewCertificateAndMismatchedKeyCannotReuse() async throws {
        for mismatch in [false, true] {
            let fixture = try setup(cached: true, missingProfile: true)
            if mismatch {
                let loaded = try await fixture.store.loadPending()
                var pending = try XCTUnwrap(loaded)
                pending = PendingSigningMaterial(privateKeyPEM: try data("profile-other-key", "pem"), csr: "synthetic-csr", certificate: pending.certificate)
                try await fixture.store.savePending(pending)
            } else { await fixture.gateway.expireCertificate() }
            _ = try await run(fixture)
            let mutations = await fixture.gateway.mutations
            XCTAssertTrue(mutations.contains("certificate"))
        }
    }

    func testQuotaRevocationIncludesExpiredCertificatesAndDecliningNeverDeletes() async throws {
        let fixture = try setup(cached: false, quota: true)
        let recorder = RevocationRecorder()
        do {
            _ = try await run(fixture) { await recorder.record($0); return false }
            XCTFail("Revocation decline ignored")
        } catch { XCTAssertEqual(error as? ProvisioningError, .revocationDeclined) }
        let candidates = await recorder.list
        XCTAssertEqual(candidates.map(\.id), ["cert", "expired"])
        let mutations = await fixture.gateway.mutations
        XCTAssertFalse(mutations.contains { $0.hasPrefix("revoke:") })
    }

    func testRemoteCertificateChangeRequiresNewConfirmationWithoutDeletion() async throws {
        let fixture = try setup(cached: false, quota: true)
        do {
            _ = try await run(fixture) { _ in await fixture.gateway.changeCertificates(); return true }
            XCTFail("Changed remote state accepted")
        } catch { XCTAssertEqual(error as? DeveloperServicesError, .remoteChanged) }
        let mutations = await fixture.gateway.mutations
        XCTAssertFalse(mutations.contains { $0.hasPrefix("revoke:") })
    }

    func testConfirmedExactRevocationsInvalidateEachLocalCertificateThenRetry() async throws {
        let fixture = try setup(cached: false, missingProfile: true, quota: true)
        _ = try await run(fixture) { _ in true }
        let mutations = await fixture.gateway.mutations
        XCTAssertEqual(mutations.filter { $0.hasPrefix("revoke:") }, ["revoke:cert", "revoke:expired"])
        let invalidated = await fixture.store.invalidated
        XCTAssertEqual(invalidated, ["cert", "expired"])
    }

    func testProfileMismatchIsNeverReturnedAndUnsupportedCapabilityStopsBeforeMutation() async throws {
        let wrong = try setup(cached: true, failProfile: true, wrongProfile: true)
        do { _ = try await run(wrong); XCTFail("Wrong profile accepted") } catch {}
        let unsupported = try setup(cached: true, capabilities: ["APP_GROUPS"])
        do { _ = try await run(unsupported); XCTFail("Unsupported capability accepted") } catch {}
        let mutations = await unsupported.gateway.mutations
        XCTAssertEqual(mutations, [])
    }

    private struct Fixture: Sendable {
        let gateway: ProvisioningGatewayFixture
        let store: PendingStoreFixture
        let keys: KeyFixture
        let anchors: [Data]
    }
    private func setup(cached: Bool, missingDevice: Bool = false, missingBundle: Bool = false, missingProfile: Bool = false,
                       failProfile: Bool = false, quota: Bool = false, wrongProfile: Bool = false, capabilities: [String] = []) throws -> Fixture {
        let cert = DeveloperCertificate(id: "cert", serial: "01", name: "Synthetic", expiry: now.addingTimeInterval(86400), der: try data("profile-dev", "cer"))
        let pending = PendingSigningMaterial(privateKeyPEM: try data("test-key", "pem"), csr: "synthetic-csr", certificate: cached ? cert : nil)
        let store = PendingStoreFixture(pending: cached ? pending : nil)
        let profile = DeveloperProfile(id: "profile", content: try data(wrongProfile ? "profile-unsigned" : "profile-valid", wrongProfile ? "plist" : "mobileprovision"))
        let gateway = ProvisioningGatewayFixture(store: store, cert: cert, profile: profile, now: now, missingDevice: missingDevice, missingBundle: missingBundle, missingProfile: missingProfile, failProfile: failProfile, quota: quota, capabilities: capabilities)
        return Fixture(gateway: gateway, store: store, keys: KeyFixture(pending: pending), anchors: [try data("profile-root", "cer")])
    }
    private func run(_ fixture: Fixture, confirmation: @escaping @Sendable ([CertificateRevocation]) async -> Bool = { _ in false }) async throws -> ProvisioningMaterial {
        let date = now
        return try await DeveloperServicesProvisioner(gateway: fixture.gateway, store: fixture.store, keys: fixture.keys, anchors: fixture.anchors, now: { date })
            .provision(app: .init(bundleID: "com.test.app", name: "Test"), deviceUDID: "SYNTHETIC-UDID", teamID: "TEAM12345", confirmRevocation: confirmation)
    }
    private func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
}

private struct KeyFixture: ProvisioningKeyGenerating { let pending: PendingSigningMaterial; func generate() throws -> PendingSigningMaterial { pending } }
private actor RevocationRecorder { var list: [CertificateRevocation] = []; func record(_ list: [CertificateRevocation]) { self.list = list } }
private actor PendingStoreFixture: ProvisioningMaterialStoring {
    var pending: PendingSigningMaterial?
    var invalidated: [String] = []
    private var failWrites = false
    init(pending: PendingSigningMaterial?) { self.pending = pending }
    func setFailWrites() { failWrites = true }
    func loadPending() async throws -> PendingSigningMaterial? { pending }
    func savePending(_ material: PendingSigningMaterial) async throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        pending = material
    }
    func invalidateCertificate(id: String) async throws { invalidated.append(id) }
}
private actor ProvisioningGatewayFixture: DeveloperServicesGateway {
    let store: PendingStoreFixture
    let cert: DeveloperCertificate
    let profile: DeveloperProfile
    var certs: [DeveloperCertificate]
    let missingDevice: Bool
    let missingBundle: Bool
    let missingProfile: Bool
    let failProfile: Bool
    var quota: Bool
    let capabilities: [String]
    var mutations: [String] = []
    private var missingIssuanceContent = false
    func setMissingIssuanceContent() { missingIssuanceContent = true; certs = [] }
    init(store: PendingStoreFixture, cert: DeveloperCertificate, profile: DeveloperProfile, now: Date, missingDevice: Bool, missingBundle: Bool, missingProfile: Bool, failProfile: Bool, quota: Bool, capabilities: [String]) {
        self.store = store; self.cert = cert; self.profile = profile; self.missingDevice = missingDevice; self.missingBundle = missingBundle
        self.missingProfile = missingProfile; self.failProfile = failProfile; self.quota = quota; self.capabilities = capabilities
        certs = [cert]
        if quota { certs.append(.init(id: "expired", serial: "02", name: "Expired", expiry: now.addingTimeInterval(-86400), der: nil)) }
    }
    func listDevices() async throws -> [DeveloperDevice] { missingDevice ? [] : [.init(id: "device", udid: "SYNTHETIC-UDID", enabled: true)] }
    func registerDevice(udid: String) async throws -> DeveloperDevice { mutations.append("device:" + udid); return .init(id: "device", udid: udid, enabled: true) }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? { missingBundle ? nil : .init(id: "bundle", identifier: "com.test.app", capabilities: capabilities) }
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle { mutations.append("bundle:" + identifier); return .init(id: "bundle", identifier: identifier, capabilities: []) }
    func listCertificates() async throws -> [DeveloperCertificate] { certs }
    func changeCertificates() { certs.append(.init(id: "new", serial: "03", name: "Changed", expiry: Date(), der: nil)) }
    func expireCertificate() { certs = [.init(id: cert.id, serial: cert.serial, name: cert.name, expiry: Date(timeIntervalSince1970: 0), der: cert.der)] }
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate {
        guard let pending = await store.pending, pending.csr == csr, !pending.privateKeyPEM.isEmpty else { throw DeveloperServicesError.invalidResponse }
        mutations.append("certificate")
        if missingIssuanceContent {
            certs = [cert]
            throw DeveloperServicesFailure(step: .createCertificate, reason: .certificateResponse(.missingContent))
        }
        if quota && !certs.isEmpty { throw DeveloperServicesError.certificateQuota }
        return cert
    }
    func revokeCertificate(id: String) async throws { mutations.append("revoke:" + id); certs.removeAll { $0.id == id } }
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] { missingProfile ? [] : [profile] }
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile {
        mutations.append("profile:\(bundleID):\(certificateID):\(deviceID)")
        if failProfile { throw DeveloperServicesError.rejected(503) }
        return profile
    }
}
