import XCTest
import Security
@testable import LocSign

final class ProvisioningKeychainTests: XCTestCase {
    func testUsesDeviceOnlyAccessibilityAndNormalizesAccount() throws {
        let api = SpyProvisioningKeychainAPI()
        let store = ProvisioningKeychain(api: api, service: "com.locsign.provisioning")

        try store.write(Data("token".utf8), account: " User@Example.com ", provider: "mac-ani-v3", team: "TEAM", key: "session")

        XCTAssertEqual(api.lastAdded?[kSecAttrAccessible] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(api.lastAdded?[kSecAttrService] as? String, "com.locsign.provisioning")
        XCTAssertEqual(try store.read(account: "user@example.com", provider: "mac-ani-v3", team: "TEAM", key: "session"),
                       Data("token".utf8))
    }

    func testFailedUpdatePreservesExistingValue() throws {
        let api = SpyProvisioningKeychainAPI()
        let store = ProvisioningKeychain(api: api)
        try store.write(Data("old".utf8), account: "user@example.com", provider: "provider", team: "TEAM", key: "session")
        api.updateStatus = errSecAuthFailed

        XCTAssertThrowsError(try store.write(Data("new".utf8), account: "user@example.com", provider: "provider", team: "TEAM", key: "session"))
        XCTAssertEqual(try store.read(account: "user@example.com", provider: "provider", team: "TEAM", key: "session"), Data("old".utf8))
    }

    func testRemoveAllOnlyDeletesOurAccountNamespace() throws {
        let api = SpyProvisioningKeychainAPI()
        let store = ProvisioningKeychain(api: api, service: "com.locsign.provisioning")
        try store.write(Data("one".utf8), account: "user@example.com", provider: "provider", team: "TEAM", key: "session")
        try store.write(Data("two".utf8), account: "other@example.com", provider: "provider", team: "TEAM", key: "session")
        try store.write(Data("second provider".utf8), account: "user@example.com", provider: "another", team: "TEAM", key: "session")
        let foreignStore = ProvisioningKeychain(api: api, service: "com.example.unrelated")
        try foreignStore.write(Data("foreign".utf8), account: "user@example.com", provider: "provider", team: "TEAM", key: "session")

        try store.removeAll(account: " user@example.com ")

        XCTAssertNil(try store.read(account: "user@example.com", provider: "provider", team: "TEAM", key: "session"))
        XCTAssertEqual(try store.read(account: "other@example.com", provider: "provider", team: "TEAM", key: "session"), Data("two".utf8))
        XCTAssertNil(try store.read(account: "user@example.com", provider: "another", team: "TEAM", key: "session"))
        XCTAssertEqual(try foreignStore.read(account: "user@example.com", provider: "provider", team: "TEAM", key: "session"), Data("foreign".utf8))
    }

    func testNamespaceComponentsCannotAliasEachOther() throws {
        let store = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        try store.write(Data("first".utf8), account: "user@example.com", provider: "a|b", team: "c", key: "session")
        try store.write(Data("second".utf8), account: "user@example.com", provider: "a", team: "b|c", key: "session")
        XCTAssertEqual(try store.read(account: "user@example.com", provider: "a|b", team: "c", key: "session"), Data("first".utf8))
        XCTAssertEqual(try store.read(account: "user@example.com", provider: "a", team: "b|c", key: "session"), Data("second".utf8))
    }

    func testLogoutDoesNotDeleteAccountContainingDelimiter() throws {
        let store = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        try store.write(Data("keep".utf8), account: "user@example.com|other", provider: "provider", team: "TEAM", key: "session")
        try store.removeAll(account: "user@example.com")
        XCTAssertEqual(try store.read(account: "user@example.com|other", provider: "provider", team: "TEAM", key: "session"), Data("keep".utf8))
    }

    func testLogoutPropagatesEnumerationFailure() throws {
        let api = SpyProvisioningKeychainAPI()
        let store = ProvisioningKeychain(api: api)
        api.enumerationStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.removeAll(account: "user@example.com")) { error in
            XCTAssertEqual((error as NSError).code, Int(errSecInteractionNotAllowed))
        }
    }

    func testMissingInstallationMarkerClearsOnlyDedicatedService() throws {
        let api = SpyProvisioningKeychainAPI()
        let store = ProvisioningKeychain(api: api)
        let foreign = ProvisioningKeychain(api: api, service: "com.example.unrelated")
        let marker = temporaryMarker()
        try store.write(Data("stale".utf8), account: "old@example.com", provider: "p", team: "", key: "session")
        try foreign.write(Data("keep".utf8), account: "old@example.com", provider: "p", team: "", key: "session")

        try store.prepareInstallation(markerURL: marker)

        XCTAssertNil(try store.read(account: "old@example.com", provider: "p", team: "", key: "session"))
        XCTAssertEqual(try foreign.read(account: "old@example.com", provider: "p", team: "", key: "session"), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try marker.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testExistingInstallationMarkerPreservesCredentialsOnUpdate() throws {
        let store = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        let marker = temporaryMarker()
        try store.prepareInstallation(markerURL: marker)
        try store.write(Data("keep".utf8), account: "user@example.com", provider: "p", team: "", key: "session")
        try store.prepareInstallation(markerURL: marker)
        XCTAssertEqual(try store.read(account: "user@example.com", provider: "p", team: "", key: "session"), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedInstallationCleanupDoesNotCreateMarkerOrLoseCredentials() throws {
        let api = SpyProvisioningKeychainAPI()
        let store = ProvisioningKeychain(api: api)
        let marker = temporaryMarker()
        try store.write(Data("keep".utf8), account: "user@example.com", provider: "p", team: "", key: "session")
        api.deleteStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.prepareInstallation(markerURL: marker))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try store.read(account: "user@example.com", provider: "p", team: "", key: "session"), Data("keep".utf8))
    }

    private func temporaryMarker() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("installation")
    }
}

final class SpyProvisioningKeychainAPI: ProvisioningKeychainAPI {
    struct Item: Hashable { let service: String; let account: String }
    var values: [Item: Data] = [:]
    var lastAdded: [CFString: Any]?
    var updateStatus: OSStatus = errSecSuccess
    var enumerationStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    private func item(_ query: [CFString: Any]) -> Item? {
        guard let service = query[kSecAttrService] as? String,
              let account = query[kSecAttrAccount] as? String else { return nil }
        return Item(service: service, account: account)
    }

    func copyData(_ query: [CFString: Any]) -> (OSStatus, Data?) {
        guard let item = item(query) else { return (errSecParam, nil) }
        return (values[item] == nil ? errSecItemNotFound : errSecSuccess, values[item])
    }

    func add(_ query: [CFString: Any]) -> OSStatus {
        lastAdded = query
        guard let item = item(query),
              let data = query[kSecValueData] as? Data else { return errSecParam }
        guard values[item] == nil else { return errSecDuplicateItem }
        values[item] = data
        return errSecSuccess
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        guard let item = item(query) else { return errSecParam }
        guard values[item] != nil else { return errSecItemNotFound }
        guard updateStatus == errSecSuccess else { return updateStatus }
        values[item] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        guard deleteStatus == errSecSuccess else { return deleteStatus }
        guard let service = query[kSecAttrService] as? String else { return errSecParam }
        let account = query[kSecAttrAccount] as? String
        values = values.filter { $0.key.service != service || (account != nil && $0.key.account != account) }
        return errSecSuccess
    }

    func matchingAccounts(service: String, accountPrefix: String) throws -> [String] {
        guard enumerationStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(enumerationStatus))
        }
        return values.keys.filter { $0.service == service && $0.account.hasPrefix(accountPrefix) }.map(\.account)
    }
}
