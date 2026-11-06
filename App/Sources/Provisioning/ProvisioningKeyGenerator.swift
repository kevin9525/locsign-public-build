import Foundation
import XKit

struct ProvisioningKeyGenerator: ProvisioningKeyGenerating {
    func generate() throws -> PendingSigningMaterial {
        let key = try Keypair()
        return PendingSigningMaterial(privateKeyPEM: try key.privateKey().data,
                                      csr: try key.generateCSR().pemString, certificate: nil)
    }
}
