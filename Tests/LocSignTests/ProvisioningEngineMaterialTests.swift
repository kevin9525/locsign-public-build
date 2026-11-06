import XCTest
import XKit
import ZIPFoundation
@testable import LocSign

final class ProvisioningEngineMaterialTests: XCTestCase {
    func testAuthenticatedMaterialCommitsAndFailedRetryPreservesActiveAndPendingKey() async throws {
        let fixture = try setup()
        let account = try await fixture.engine.logIn(appleID: "user@example.com", password: "synthetic", twoFactorCode: { nil })
        let request = ProvisioningRequest(accountID: account.id, teamID: "TEAM12345", ipaURL: fixture.ipa, deviceUDID: "SYNTHETIC-UDID")
        let material = try await fixture.engine.provision(request: request, confirmRevocation: { _ in false })
        XCTAssertEqual(material.profileData, try data("profile-valid", "mobileprovision"))
        let active = try XCTUnwrap(fixture.keychain.read(account: account.appleID, provider: "signing-material-v1", team: request.teamID, key: "active"))
        fixture.backend.rejectProfile()
        do { _ = try await fixture.engine.provision(request: request, confirmRevocation: { _ in false }); XCTFail("Unsigned profile accepted") }
        catch { XCTAssertEqual(error as? ProfileValidationError, .cms) }
        XCTAssertEqual(try fixture.keychain.read(account: account.appleID, provider: "signing-material-v1", team: request.teamID, key: "active"), active)
        let pendingBytes = try XCTUnwrap(fixture.keychain.read(account: account.appleID, provider: "signing-material-v1", team: request.teamID, key: "pending"))
        let pending = try JSONDecoder().decode(PendingSigningMaterial.self, from: pendingBytes)
        XCTAssertEqual(pending.privateKeyPEM, try data("test-key", "pem"))
        XCTAssertEqual(pending.certificate?.id, "cert")
    }

    func testProviderChangeDropsOldADIAndSessionButPreservesSigningIdentity() async throws {
        let fixture = try setup()
        let account = try await fixture.engine.logIn(appleID: "user@example.com", password: "synthetic", twoFactorCode: { nil })
        let request = ProvisioningRequest(accountID: account.id, teamID: "TEAM12345", ipaURL: fixture.ipa, deviceUDID: "SYNTHETIC-UDID")
        _ = try await fixture.engine.provision(request: request, confirmRevocation: { _ in false })
        let original = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        try fixture.keychain.write(Data([7]), account: account.appleID, provider: original.providerID, team: "", key: "anisette.XTLProvisioningInfo")
        let backend = fixture.backend
        let other = try ProvisioningEngineLive(configuration: .init(endpoint: URL(string: "https://other.invalid")!),
            keychain: fixture.keychain, markerURL: fixture.marker, makeBackend: { _ in backend })
        let restored = try await other.restoreAccount()
        XCTAssertNil(restored)
        XCTAssertNil(try fixture.keychain.read(account: account.appleID, provider: original.providerID, team: "", key: "anisette.XTLProvisioningInfo"))
        XCTAssertNotNil(try fixture.keychain.read(account: account.appleID, provider: "signing-material-v1", team: "TEAM12345", key: "pending"))
        try await other.logout(account: account.appleID)
        XCTAssertNil(try fixture.keychain.read(account: account.appleID, provider: "signing-material-v1", team: "TEAM12345", key: "pending"))
        XCTAssertNil(try fixture.keychain.read(account: account.appleID, provider: "signing-material-v1", team: "TEAM12345", key: "active"))
    }

    private struct Fixture {
        let engine: ProvisioningEngineLive
        let keychain: ProvisioningKeychain
        let backend: MaterialBackendFixture
        let ipa: URL
        let marker: URL
    }
    private func setup() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("staging/Payload/Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PlistCodec.encodeXML(["CFBundleIdentifier": "com.test.app", "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"])
            .write(to: app.appendingPathComponent("Info.plist"))
        try ProvisioningIPAPreflightTests.macho().write(to: app.appendingPathComponent("Test"))
        let ipa = root.appendingPathComponent("test.ipa")
        try FileManager.default.zipItem(at: root.appendingPathComponent("staging"), to: ipa, shouldKeepParent: false)
        let backend = MaterialBackendFixture(pending: PendingSigningMaterial(privateKeyPEM: try data("test-key", "pem"), csr: "synthetic-csr",
            certificate: .init(id: "cert", serial: "01", name: "Synthetic", expiry: Date(timeIntervalSince1970: 4_000_000_000), der: try data("profile-dev", "cer"))),
            profile: try data("profile-valid", "mobileprovision"), badProfile: try data("profile-unsigned", "plist"))
        let keychain = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        let marker = root.appendingPathComponent("marker")
        let engine = try ProvisioningEngineLive(configuration: .init(endpoint: URL(string: "https://fixture.invalid")!),
            keychain: keychain, markerURL: marker, trustAnchors: [try data("profile-root", "cer")], makeBackend: { _ in backend })
        return Fixture(engine: engine, keychain: keychain, backend: backend, ipa: ipa, marker: marker)
    }
    private func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
}

private final class MaterialBackendFixture: ProvisioningBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var useBadProfile = false
    let pending: PendingSigningMaterial
    let profile: Data
    let badProfile: Data
    init(pending: PendingSigningMaterial, profile: Data, badProfile: Data) {
        self.pending = pending; self.profile = profile; self.badProfile = badProfile
    }
    func rejectProfile() { lock.withLock { useBadProfile = true } }
    func invalidate() {}
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession {
        AppleAccountSession(account: .init(id: UUID(), appleID: appleID, teams: [.init(id: "TEAM12345", name: "Synthetic")]),
            token: .init(adsid: "synthetic-adsid", token: "synthetic-token", expiry: Date().addingTimeInterval(3600)), providerID: "omnisette-v3:https://fixture.invalid")
    }
    func provision(request: ProvisioningRequest, session: AppleAccountSession, store: any ProvisioningMaterialStoring,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        try await store.savePending(pending)
        return ProvisioningMaterial(privateKeyPEM: String(data: pending.privateKeyPEM, encoding: .utf8)!,
            profileData: lock.withLock { useBadProfile ? badProfile : profile },
            certificateExpiry: pending.certificate!.expiry, profileExpiry: Date(timeIntervalSince1970: 4_000_000_000))
    }
}
