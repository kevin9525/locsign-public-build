import Foundation
import CryptoKit

enum ProvisioningSigningIdentifier {
    static func validate(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 255,
              value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw ProvisioningError.unsupportedIPA("签名标识须由字母、数字、短横线和点组成，至少包含两段，且不超过 255 字节")
        }
        return value
    }

    static func personal(original: String, teamID: String) throws -> String {
        let original = try validate(original)
        guard !teamID.isEmpty else { throw ProvisioningError.noDeveloperTeam }
        func hash(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        // Stable across login/reinstall, without exposing account or device IDs.
        return "com.locsign.personal.t\(hash(teamID).prefix(16)).a\(hash(original).prefix(32))"
    }
}

extension ProvisioningRequest {
    func inspectedApp() throws -> ProvisioningApp {
        let target = try signingBundleID.map(ProvisioningSigningIdentifier.validate)
        // Inspect original entitlement claims against the original identity.
        // A selected target must never authorize permissions in the input IPA.
        let original = try ProvisioningIPAPreflight().inspect(ipaURL)
        return ProvisioningApp(bundleID: target ?? original.bundleID, name: original.name)
    }
}
