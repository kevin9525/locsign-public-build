import Foundation

struct ProvisioningKeyGenerator: ProvisioningKeyGenerating {
    func generate() throws -> PendingSigningMaterial { throw DeveloperServicesError.invalidResponse }
}
