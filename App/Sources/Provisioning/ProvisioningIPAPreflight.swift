import Foundation

struct ProvisioningApp: Sendable, Equatable {
    let bundleID: String
    let name: String
}

struct ProvisioningIPAPreflight: Sendable {
    func inspect(_ ipaURL: URL) throws -> ProvisioningApp {
        throw ProvisioningError.unsupportedIPA("尚未验证")
    }
}
