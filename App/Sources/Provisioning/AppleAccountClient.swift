import Foundation
import XKit

typealias TwoFactorCodeProvider = @Sendable () async -> String?

struct AppleAccountSession: Sendable {
    let account: ProvisioningAccount
    let token: DeveloperServicesLoginToken
    let providerID: String
}

protocol AppleAccountGateway: Sendable {
    func authenticate(appleID: String, password: String, twoFactor: @escaping TwoFactorCodeProvider) async throws -> DeveloperServicesLoginToken
    func teams(token: DeveloperServicesLoginToken) async throws -> [DeveloperServicesTeam]
}

protocol AppleAccountAuthenticating: Sendable {
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession
}

struct AppleAccountClient: AppleAccountAuthenticating {
    let gateway: any AppleAccountGateway
    let providerID: String
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession {
        do {
            try Task.checkCancellation()
            let normalized = ProvisioningKeychain.normalize(appleID)
            guard !normalized.isEmpty, !password.isEmpty else { throw AppleAccountError.invalidCredentials }
            let token = try await gateway.authenticate(appleID: normalized, password: password, twoFactor: twoFactorCode)
            try Task.checkCancellation()
            guard token.expiry > Date(), !token.adsid.isEmpty, !token.token.isEmpty else { throw AppleAccountError.rejected(nil) }
            let teams = try await gateway.teams(token: token)
            try Task.checkCancellation()
            var ids = Set<String>()
            let supported = teams.filter {
                $0.status.lowercased() == "active" && $0.isFree &&
                $0.memberships.contains { $0.platform == .iOS } && ids.insert($0.id.rawValue).inserted
            }.map { ProvisioningTeam(id: $0.id.rawValue, name: $0.name) }
            guard !supported.isEmpty else { throw AppleAccountError.noDeveloperTeam }
            return AppleAccountSession(account: ProvisioningAccount(id: UUID(), appleID: normalized, teams: supported), token: token, providerID: providerID)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? AppleAccountError { throw error }
            if error is URLError || error is ProvisioningNetworkError { throw AppleAccountError.network }
            throw AppleAccountError.rejected(nil)
        }
    }
}

enum AppleAccountError: Error, LocalizedError, Equatable {
    case invalidCredentials, accountLocked, invalidCode, cancelled, unavailable, network, noDeveloperTeam, rejected(Int?)
    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Apple ID 或密码错误，请重新登录"
        case .accountLocked: return "Apple 账号已锁定，请先在 Apple 账号页面恢复"
        case .invalidCode: return "验证码未通过，请重新输入密码登录并获取验证码"
        case .cancelled: return "登录已取消"
        case .unavailable: return "Anisette 数据不可用，请检查提供方或重新登录"
        case .network: return "认证网络请求失败，请检查连接后重试"
        case .noDeveloperTeam: return "账号没有可用的免费 iOS 开发团队"
        case .rejected(let code): return "Apple 认证未通过" + (code.map { "（\($0)）" } ?? "") + "，请稍后重新登录"
        }
    }
}
