import Foundation

struct ProvisioningTeam: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct ProvisioningAccount: Codable, Sendable, Equatable {
    let id: UUID
    let appleID: String
    let teams: [ProvisioningTeam]
}

struct ProvisioningRequest: Sendable {
    let accountID: UUID
    let teamID: String
    let ipaURL: URL
    let deviceUDID: String
    var signingBundleID: String? = nil
    var minimumProfileExpiry: Date? = nil
}

struct CertificateRevocation: Sendable, Equatable, Identifiable {
    let id: String
    let serialNumber: String
    let name: String
    let expiry: Date
}

/// One app extension's own profile. Every extension needs its own App ID and
/// development profile bound to the same certificate and device as the app.
struct ExtensionProfileMaterial: Codable, Sendable, Equatable {
    let bundleID: String
    let profileData: Data
    let profileExpiry: Date
}

struct ProvisioningMaterial: Codable, Sendable {
    let privateKeyPEM: String
    let profileData: Data
    let certificateExpiry: Date
    /// Effective expiry: the earliest of the app and all extension profiles.
    let profileExpiry: Date
    var signingBundleID: String? = nil
    // Optional so material saved before extension support still decodes.
    var extensionProfiles: [ExtensionProfileMaterial]? = nil

    var extensions: [ExtensionProfileMaterial] { extensionProfiles ?? [] }
}

extension Array where Element == ExtensionProfileMaterial {
    /// Extensions must be signed exactly once each, regardless of order.
    var sortedBundleIDs: [String] { map(\.bundleID).sorted() }
}

enum ProvisioningError: LocalizedError, Equatable {
    case cancelled
    case invalidAccount
    case noDeveloperTeam
    case providerUnavailable(String)
    case unsupportedIPA(String)
    case materialInvalid(String)
    case revocationDeclined
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "操作已取消"
        case .invalidAccount: return "Apple ID 登录会话已失效，请重新登录"
        case .noDeveloperTeam: return "账号没有可用的 Apple 开发团队"
        case .providerUnavailable(let detail): return "Anisette 服务不可用：\(detail)"
        case .unsupportedIPA(let detail): return "当前 IPA 不支持自动申请材料：\(detail)"
        case .materialInvalid(let detail): return "Apple 签名材料无效：\(detail)"
        case .revocationDeclined: return "未确认撤销证书，已保留原有材料"
        case .remote(let detail): return "Apple Developer Services 请求失败：\(detail)"
        }
    }
}
