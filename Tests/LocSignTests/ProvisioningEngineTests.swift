import XCTest
import XKit
@testable import LocSign

final class ProvisioningEngineTests: XCTestCase {
    func testLoginPersistsSessionRestoresOpaqueHandleAndLogoutClearsAccount() async throws {
        let fixture = try setup()
        let account = try await fixture.engine.logIn(appleID: " User@Example.com ", password: "synthetic-password", twoFactorCode: { nil })
        let restored = try await fixture.engine.restoreAccount()
        XCTAssertEqual(restored, account)
        let second = try engine(keychain: fixture.keychain, marker: fixture.marker, backend: fixture.backend)
        let restoredAgain = try await second.restoreAccount()
        XCTAssertEqual(restoredAgain?.id, account.id)
        try await fixture.engine.logout(account: account.appleID)
        let afterLogout = try await second.restoreAccount()
        XCTAssertNil(afterLogout)
    }

    func testLogoutDuringLoginRejectsLateResponseAndDoesNotRecreateCredentials() async throws {
        let fixture = try setup(delayedLogin: true)
        let task = Task { try await fixture.engine.logIn(appleID: "user@example.com", password: "synthetic-password", twoFactorCode: { nil }) }
        await fulfillment(of: [fixture.backend.loginStarted], timeout: 2)
        try await fixture.engine.logout(account: "user@example.com")
        fixture.backend.releaseLogin()
        do { _ = try await task.value; XCTFail("Late login accepted") } catch {}
        let restored = try await fixture.engine.restoreAccount()
        XCTAssertNil(restored)
        XCTAssertTrue(fixture.backend.invalidated)
    }

    func testCancelDuringProvisionBlocksLatePendingAndActiveWrites() async throws {
        let fixture = try setup(delayedProvision: true)
        let account = try await fixture.engine.logIn(appleID: "user@example.com", password: "synthetic-password", twoFactorCode: { nil })
        let request = ProvisioningRequest(accountID: account.id, teamID: "TEAM", ipaURL: URL(fileURLWithPath: "/synthetic.ipa"), deviceUDID: "UDID")
        let task = Task { try await fixture.engine.provision(request: request, confirmRevocation: { _ in false }) }
        await fulfillment(of: [fixture.backend.provisionStarted], timeout: 2)
        await fixture.engine.cancel()
        fixture.backend.releaseProvision()
        do { _ = try await task.value; XCTFail("Late material accepted") } catch {}
        XCTAssertTrue(fixture.backend.pendingWriteRejected)
    }

    func testInvalidAccountAndTeamNeverReachProvisioningBackend() async throws {
        let fixture = try setup()
        let account = try await fixture.engine.logIn(appleID: "user@example.com", password: "synthetic-password", twoFactorCode: { nil })
        for request in [ProvisioningRequest(accountID: UUID(), teamID: "TEAM", ipaURL: URL(fileURLWithPath: "/synthetic.ipa"), deviceUDID: "UDID"),
                        ProvisioningRequest(accountID: account.id, teamID: "FOREIGN", ipaURL: URL(fileURLWithPath: "/synthetic.ipa"), deviceUDID: "UDID")] {
            do { _ = try await fixture.engine.provision(request: request, confirmRevocation: { _ in true }); XCTFail("Foreign context accepted") }
            catch { XCTAssertEqual(error as? ProvisioningError, .invalidAccount) }
        }
        XCTAssertEqual(fixture.backend.provisionCalls, 0)
    }

    func testProviderMismatchAndExpiredSessionRequireLogin() async throws {
        let fixture = try setup()
        _ = try await fixture.engine.logIn(appleID: "user@example.com", password: "synthetic-password", twoFactorCode: { nil })
        let other = try engine(keychain: fixture.keychain, marker: fixture.marker, backend: fixture.backend, endpoint: "https://other.invalid")
        let restored = try await other.restoreAccount()
        XCTAssertNil(restored)
        let expired = try setup(expired: true)
        do { _ = try await expired.engine.logIn(appleID: "user@example.com", password: "synthetic-password", twoFactorCode: { nil }); XCTFail("Expired session accepted") } catch {}
    }

    private struct Fixture { let engine: ProvisioningEngineLive; let keychain: ProvisioningKeychain; let marker: URL; let backend: EngineBackendFixture }
    private func setup(delayedLogin: Bool = false, delayedProvision: Bool = false, expired: Bool = false) throws -> Fixture {
        let keychain = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("marker")
        addTeardownBlock { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let backend = EngineBackendFixture(delayedLogin: delayedLogin, delayedProvision: delayedProvision, expired: expired)
        return Fixture(engine: try engine(keychain: keychain, marker: marker, backend: backend), keychain: keychain, marker: marker, backend: backend)
    }
    private func engine(keychain: ProvisioningKeychain, marker: URL, backend: EngineBackendFixture, endpoint: String = "https://fixture.invalid") throws -> ProvisioningEngineLive {
        try ProvisioningEngineLive(configuration: AnisetteProviderConfiguration(endpoint: URL(string: endpoint)!), keychain: keychain, markerURL: marker, makeBackend: { _ in backend })
    }
}

private final class EngineBackendFixture: ProvisioningBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var loginWaiter: CheckedContinuation<Void, Never>?
    private var provisionWaiter: CheckedContinuation<Void, Never>?
    let loginStarted = XCTestExpectation(description: "Login entered backend")
    let provisionStarted = XCTestExpectation(description: "Provision entered backend")
    private let delayedLogin: Bool
    private let delayedProvision: Bool
    private let expired: Bool
    private var revoked = false
    private var rejected = false
    private var calls = 0
    var invalidated: Bool { lock.withLock { revoked } }
    var pendingWriteRejected: Bool { lock.withLock { rejected } }
    var provisionCalls: Int { lock.withLock { calls } }
    init(delayedLogin: Bool, delayedProvision: Bool, expired: Bool) {
        self.delayedLogin = delayedLogin; self.delayedProvision = delayedProvision; self.expired = expired
    }
    func releaseLogin() { lock.withLock { loginWaiter?.resume(); loginWaiter = nil } }
    func releaseProvision() { lock.withLock { provisionWaiter?.resume(); provisionWaiter = nil } }
    func invalidate() { lock.withLock { revoked = true } }
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession {
        if delayedLogin {
            await withCheckedContinuation { continuation in
                lock.withLock { loginWaiter = continuation }
                loginStarted.fulfill()
            }
        }
        return AppleAccountSession(account: ProvisioningAccount(id: UUID(), appleID: appleID, teams: [.init(id: "TEAM", name: "Personal")]), token: .init(adsid: "synthetic-adsid", token: "synthetic-token", expiry: Date().addingTimeInterval(expired ? -3600 : 3600)), providerID: "omnisette-v3:https://fixture.invalid")
    }
    func provision(request: ProvisioningRequest, session: AppleAccountSession, store: any ProvisioningMaterialStoring,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        lock.withLock { calls += 1 }
        if delayedProvision {
            await withCheckedContinuation { continuation in
                lock.withLock { provisionWaiter = continuation }
                provisionStarted.fulfill()
            }
        }
        do { try await store.savePending(.init(privateKeyPEM: Data("synthetic-key".utf8), csr: "synthetic-csr", certificate: nil)) }
        catch { lock.withLock { rejected = true }; throw error }
        return ProvisioningMaterial(privateKeyPEM: "synthetic-key", profileData: Data("synthetic-profile".utf8), certificateExpiry: Date().addingTimeInterval(3600), profileExpiry: Date().addingTimeInterval(3600))
    }
}
