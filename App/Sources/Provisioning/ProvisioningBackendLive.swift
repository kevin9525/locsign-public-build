import Foundation
import XKit

struct ProvisioningBackendLive: ProvisioningBackend {
    init(configuration: AnisetteProviderConfiguration, keychain: ProvisioningKeychain, account: String) throws {}
    func invalidate() {}
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession {
        throw ProvisioningError.providerUnavailable("尚未接入")
    }
    func provision(request: ProvisioningRequest, session: AppleAccountSession, store: any ProvisioningMaterialStoring,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        throw ProvisioningError.materialInvalid("尚未接入")
    }
}
