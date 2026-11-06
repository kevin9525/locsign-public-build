import Foundation
import Security

protocol ProvisioningKeychainAPI {
    func copyData(_ query: [CFString: Any]) -> (OSStatus, Data?)
    func add(_ query: [CFString: Any]) -> OSStatus
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
    func matchingAccounts(service: String, accountPrefix: String) throws -> [String]
}

private func provisioningKeychainError(_ status: OSStatus) -> NSError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
}

private final class SystemProvisioningKeychainAPI: ProvisioningKeychainAPI {
    func copyData(_ query: [CFString: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ query: [CFString: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func matchingAccounts(service: String, accountPrefix: String) throws -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecUseDataProtectionKeychain: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw provisioningKeychainError(status) }
        guard let rows = result as? [[CFString: Any]] else { throw provisioningKeychainError(errSecDecode) }
        return try rows.compactMap { row in
            guard let account = row[kSecAttrAccount] as? String else { throw provisioningKeychainError(errSecDecode) }
            return account.hasPrefix(accountPrefix) ? account : nil
        }
    }
}

// All API calls and compound read/update/delete operations are serialized by lock.
// No mutable API reference is exposed by this store; production uses the stateless system adapter.
final class ProvisioningKeychain: @unchecked Sendable {
    static let service = "com.locsign.provisioning"
    let accessibility: String

    private let api: ProvisioningKeychainAPI
    private let serviceName: String
    private let lock = NSRecursiveLock()
    private static let markerContents = Data("LocSign provisioning installation marker v1\n".utf8)

    init(api: ProvisioningKeychainAPI? = nil, service: String = ProvisioningKeychain.service) {
        self.api = api ?? SystemProvisioningKeychainAPI()
        self.serviceName = service
        self.accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    }

    func read(account: String, provider: String, team: String, key: String) throws -> Data? {
        try lock.withLock {
            let query = baseQuery(account: account, provider: provider, team: team, key: key)
            let (status, data) = api.copyData(query.merging([kSecReturnData: true]) { _, new in new })
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw provisioningKeychainError(status) }
            guard let data else { throw provisioningKeychainError(errSecDecode) }
            return data
        }
    }

    func write(_ data: Data, account: String, provider: String, team: String, key: String) throws {
        try lock.withLock {
            let query = baseQuery(account: account, provider: provider, team: team, key: key)
            let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: accessibility]
            let status = api.update(query, attributes: attributes)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw provisioningKeychainError(status) }
            let addStatus = api.add(query.merging(attributes) { _, new in new })
            guard addStatus == errSecSuccess else { throw provisioningKeychainError(addStatus) }
        }
    }

    func remove(account: String, provider: String, team: String, key: String) throws {
        try lock.withLock {
            try checkDeletion(api.delete(baseQuery(account: account, provider: provider, team: team, key: key)))
        }
    }

    func removeAll(account: String) throws {
        try lock.withLock {
            let prefix = "v1|" + Self.component(Self.normalize(account)) + "|"
            for storedAccount in try api.matchingAccounts(service: serviceName, accountPrefix: prefix) {
                var query = serviceQuery
                query[kSecAttrAccount] = storedAccount
                try checkDeletion(api.delete(query))
            }
        }
    }

    /// Called before restoring credentials. A missing sandbox marker means Keychain
    /// items may belong to an earlier installation; the dedicated service is cleared.
    func prepareInstallation(markerURL: URL) throws {
        try lock.withLock {
            let fm = FileManager.default
            if fm.fileExists(atPath: markerURL.path),
               try Data(contentsOf: markerURL) == Self.markerContents { return }

            try checkDeletion(api.delete(serviceQuery))
            var directory = markerURL.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            var marker = markerURL
            do {
                try Self.markerContents.write(to: marker, options: [.atomic, .completeFileProtection])
                try marker.setResourceValues(attributes)
            } catch {
                // A partially created marker must not suppress cleanup on the next launch.
                try? fm.removeItem(at: marker)
                throw error
            }
        }
    }

    static func normalize(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func component(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private var serviceQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: serviceName, kSecUseDataProtectionKeychain: true]
    }

    private func baseQuery(account: String, provider: String, team: String, key: String) -> [CFString: Any] {
        var query = serviceQuery
        query[kSecAttrAccount] = "v1|" + [Self.normalize(account), provider, team, key].map(Self.component).joined(separator: "|")
        return query
    }

    private func checkDeletion(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else { throw provisioningKeychainError(status) }
    }
}
