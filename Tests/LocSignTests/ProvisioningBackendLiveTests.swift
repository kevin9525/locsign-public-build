import XCTest
import XKit
@testable import LocSign

final class ProvisioningBackendLiveTests: XCTestCase {
    func testInvalidatedBackendRejectsLoginBeforeProviderTraffic() async throws {
        let configuration = try AnisetteProviderConfiguration(endpoint: URL(string: "https://unused.invalid")!)
        let backend = try ProvisioningBackendLive(configuration: configuration,
            keychain: ProvisioningKeychain(api: SpyProvisioningKeychainAPI()), account: "user@example.com")
        backend.invalidate()
        do {
            _ = try await backend.logIn(appleID: "user@example.com", password: "synthetic", twoFactorCode: { nil })
            XCTFail("Invalidated backend accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPreflightRejectsMalformedIPAWithoutSavingMaterialOrCallingProvider() async throws {
        let configuration = try AnisetteProviderConfiguration(endpoint: URL(string: "https://unused.invalid")!)
        let backend = try ProvisioningBackendLive(configuration: configuration,
            keychain: ProvisioningKeychain(api: SpyProvisioningKeychainAPI()), account: "user@example.com")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data("invalid-ipa".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = ProvisioningAccount(id: UUID(), appleID: "user@example.com", teams: [.init(id: "TEAM12345", name: "Synthetic")])
        let session = AppleAccountSession(account: account, token: .init(adsid: "synthetic", token: "synthetic", expiry: .distantFuture), providerID: configuration.providerID)
        let store = BackendStoreFixture()
        do {
            _ = try await backend.provision(request: .init(accountID: account.id, teamID: "TEAM12345", ipaURL: url, deviceUDID: "SYNTHETIC-UDID"),
                session: session, store: store, confirmRevocation: { _ in false })
            XCTFail("Malformed IPA accepted")
        } catch ProvisioningError.unsupportedIPA { }
        catch { XCTFail("Expected local preflight rejection, got \(type(of: error))") }
        let writes = await store.writes
        XCTAssertEqual(writes, 0)
    }
}

private actor BackendStoreFixture: ProvisioningMaterialStoring {
    private(set) var writes = 0
    func loadPending() async throws -> PendingSigningMaterial? { nil }
    func savePending(_ material: PendingSigningMaterial) async throws { writes += 1 }
    func invalidateCertificate(id: String) async throws {}
}
