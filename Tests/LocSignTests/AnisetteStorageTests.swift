import XCTest
import Security
import Dependencies
import XKit
@testable import LocSign

final class AnisetteStorageTests: XCTestCase {
    func testADIStorageUsesKeychainProviderNamespaceAndPropagatesFailure() throws {
        let api = SpyProvisioningKeychainAPI()
        let keychain = ProvisioningKeychain(api: api)
        let a = AnisetteKeychainStorage(keychain: keychain, account: "user@example.com", provider: "provider-a")
        let b = AnisetteKeychainStorage(keychain: keychain, account: "user@example.com", provider: "provider-b")
        try a.setData(Data([1]), forKey: "state")
        XCTAssertEqual(try a.data(forKey: "state"), Data([1]))
        XCTAssertNil(try b.data(forKey: "state"))
        api.updateStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try a.setData(Data([2]), forKey: "state"))
        XCTAssertEqual(try a.data(forKey: "state"), Data([1]))
        api.updateStatus = errSecSuccess
        try a.setData(nil, forKey: "state")
        XCTAssertNil(try a.data(forKey: "state"))
    }

    func testInvalidatedStorageCannotRecreateCredentialsAfterLogout() throws {
        let keychain = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        let storage = AnisetteKeychainStorage(keychain: keychain, account: "user@example.com", provider: "provider")
        try storage.setData(Data([1]), forKey: "state")
        storage.invalidate()
        try keychain.removeAll(account: "user@example.com")
        XCTAssertThrowsError(try storage.setData(Data([2]), forKey: "state")) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try storage.data(forKey: "state")) { XCTAssertTrue($0 is CancellationError) }
        let fresh = AnisetteKeychainStorage(keychain: keychain, account: "user@example.com", provider: "provider")
        XCTAssertNil(try fresh.data(forKey: "state"))
    }

    func testCheckedADIInitializerRejectsStorageFailureAndExposesProviderIdentity() throws {
        let storage = FailableADIStorage()
        storage.failWrites = true
        XCTAssertThrowsError(try withDependencies {
            $0.keyValueStorage = storage
        } operation: {
            try ADIDataProvider(providerID: "omnisette-v3:https://fixture.invalid")
        })
        storage.failWrites = false
        let provider = try withDependencies { $0.keyValueStorage = storage } operation: {
            try ADIDataProvider(providerID: "omnisette-v3:https://fixture.invalid")
        }
        XCTAssertEqual(provider.providerID, "omnisette-v3:https://fixture.invalid")
        let uuid = try storage.string(forKey: "XTLLocalUserUID")
        XCTAssertNotNil(uuid.flatMap(UUID.init(uuidString:)))
    }

    func testProviderChangeClearsOldADIAndSameProviderRetainsIt() throws {
        let storage = FailableADIStorage()
        _ = try withDependencies { $0.keyValueStorage = storage } operation: { try ADIDataProvider(providerID: "a") }
        try storage.setData(Data([1]), forKey: "XTLProvisioningInfo")
        try storage.setString("42", forKey: "XTLRoutingInfo")
        _ = try withDependencies { $0.keyValueStorage = storage } operation: { try ADIDataProvider(providerID: "a") }
        XCTAssertEqual(try storage.data(forKey: "XTLProvisioningInfo"), Data([1]))
        _ = try withDependencies { $0.keyValueStorage = storage } operation: { try ADIDataProvider(providerID: "b") }
        XCTAssertNil(try storage.data(forKey: "XTLProvisioningInfo"))
        XCTAssertNil(try storage.string(forKey: "XTLRoutingInfo"))
    }
}

private final class FailableADIStorage: KeyValueStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failing = false
    var failWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func data(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func setData(_ data: Data?, forKey key: String) throws {
        try lock.withLock {
            if failing { throw URLError(.cannotWriteToFile) }
            values[key] = data
        }
    }
}
