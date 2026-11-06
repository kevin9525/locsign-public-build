import Foundation

protocol ProvisioningEngine: Sendable {
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount
    func restoreAccount() async throws -> ProvisioningAccount?
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial
    func cancel() async
    func logout(account: String) async throws
}

protocol ProvisioningBackend: Sendable {
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession
    func provision(request: ProvisioningRequest, session: AppleAccountSession, store: any ProvisioningMaterialStoring,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial
    func invalidate()
}

actor ProvisioningEngineLive: ProvisioningEngine {
    typealias BackendFactory = @Sendable (String) throws -> any ProvisioningBackend
    init(configuration: AnisetteProviderConfiguration, keychain: ProvisioningKeychain, markerURL: URL,
         makeBackend: @escaping BackendFactory) throws {}
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount { throw ProvisioningError.invalidAccount }
    func restoreAccount() async throws -> ProvisioningAccount? { nil }
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial { throw ProvisioningError.invalidAccount }
    func cancel() async {}
    func logout(account: String) async throws {}
}
