import Foundation
import XKit

final class AnisetteKeychainStorage: KeyValueStorage, @unchecked Sendable {
    // The gate and every synchronous Keychain call share the lock. invalidate()
    // returns only after a prior write completes; later writes cannot repopulate it.
    private let lock = NSLock()
    private var valid = true
    private let keychain: ProvisioningKeychain
    private let account: String
    private let provider: String

    init(keychain: ProvisioningKeychain, account: String, provider: String) {
        self.keychain = keychain
        self.account = account
        self.provider = provider
    }
    func data(forKey key: String) throws -> Data? {
        try lock.withLock {
            guard valid else { throw CancellationError() }
            try Task.checkCancellation()
            return try keychain.read(account: account, provider: provider, team: "", key: "anisette." + key)
        }
    }
    func setData(_ data: Data?, forKey key: String) throws {
        try lock.withLock {
            guard valid else { throw CancellationError() }
            try Task.checkCancellation()
            if let data {
                try keychain.write(data, account: account, provider: provider, team: "", key: "anisette." + key)
            } else {
                try keychain.remove(account: account, provider: provider, team: "", key: "anisette." + key)
            }
        }
    }
    func invalidate() { lock.withLock { valid = false } }
}
