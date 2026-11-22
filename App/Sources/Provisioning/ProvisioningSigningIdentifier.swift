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

    /// iOS requires an extension's identifier to extend its app's identifier.
    /// When the app is signed under another identifier, each extension keeps
    /// its own suffix under that identifier (`a.b.widget` → `x.y.widget`).
    static func extensionIdentifier(_ extensionID: String, originalApp: String, targetApp: String) throws -> String {
        guard extensionID.hasPrefix(originalApp + "."), extensionID.count > originalApp.count + 1 else {
            throw ProvisioningError.unsupportedIPA("扩展标识不属于主 App")
        }
        if originalApp == targetApp { return try validate(extensionID) }
        return try validate(targetApp + String(extensionID.dropFirst(originalApp.count)))
    }
}

extension ProvisioningRequest {
    func inspectedApp() throws -> ProvisioningApp {
        let target = try signingBundleID.map(ProvisioningSigningIdentifier.validate)
        // Inspect original entitlement claims against the original identity.
        // A selected target must never authorize permissions in the input IPA.
        let original = try ProvisioningIPAPreflight().inspect(ipaURL)
        let bundleID = target ?? original.bundleID
        let extensions = try original.extensions.map {
            try ProvisioningExtension(bundleID: ProvisioningSigningIdentifier.extensionIdentifier(
                $0.bundleID, originalApp: original.bundleID, targetApp: bundleID), name: $0.name)
        }.sorted { $0.bundleID < $1.bundleID }
        return ProvisioningApp(bundleID: bundleID, name: original.name, extensions: extensions)
    }
}
