import Foundation
import CryptoKit

struct ValidatedProvisioningProfile {
    let raw: Data
    let signedContent: Data
    let profile: ProvisioningProfileData
    let uuid: String
    let certificateDER: Data
    let certificateExpiry: Date
    var expiry: Date { profile.expiry }
}

enum ProfileValidationError: LocalizedError, Equatable {
    case cms
    case metadata
    case certificate
    case expired

    var errorDescription: String? {
        switch self {
        case .cms: return "描述文件的 Apple 签名或签发链无效，请重新获取材料"
        case .metadata: return "描述文件与所选团队、应用或设备不匹配，或包含不支持的权限"
        case .certificate: return "开发证书已失效或与本地私钥不匹配，请重新获取材料"
        case .expired: return "描述文件已过期，请重新获取材料"
        }
    }
}

struct ProvisioningProfileValidator {
    let trustAnchors: [Data]
    let now: Date

    init(trustAnchors: [Data], now: Date = Date()) {
        self.trustAnchors = trustAnchors
        self.now = now
    }

    static func apple(now: Date = Date()) throws -> Self {
        let roots = [
            ("AppleIncRootCertificate", "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024"),
            ("AppleRootCA-G2", "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050"),
            ("AppleRootCA-G3", "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179")
        ]
        let anchors = try roots.map { name, hash -> Data in
            guard let url = Bundle.main.url(forResource: name, withExtension: "cer"),
                  let data = try? Data(contentsOf: url),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash
            else { throw ProfileValidationError.cms }
            return data
        }
        return Self(trustAnchors: anchors, now: now)
    }

    func validate(data: Data, expectedBundleID: String, expectedTeamID: String,
                  expectedUDID: String, expectedCertificateDER: Data,
                  privateKeyPEM: Data) throws -> ValidatedProvisioningProfile {
        guard let signedContent = LocSignVerifyProvisioningCMS(data, trustAnchors, now) else {
            throw ProfileValidationError.cms
        }
        let profile: ProvisioningProfileData
        do {
            let contentSlice = try ProfileParser.payloadData(from: signedContent)
            // Whitespace outside the XML is allowed only inside the signed content.
            let stripped = Data(signedContent.drop(while: Self.isWhitespace).reversed()
                .drop(while: Self.isWhitespace).reversed())
            guard stripped == contentSlice, try ProfileParser.payloadData(from: data) == contentSlice else {
                throw ProfileValidationError.metadata
            }
            profile = try ProfileParser.parse(data)
        } catch { throw ProfileValidationError.metadata }
        let payload = profile.payload
        guard !expectedBundleID.isEmpty, !expectedTeamID.isEmpty, !expectedUDID.isEmpty,
              !expectedBundleID.contains("*"),
              let uuid = payload["UUID"] as? String, UUID(uuidString: uuid) != nil,
              let teams = payload["TeamIdentifier"] as? [String], teams == [expectedTeamID],
              let prefixes = payload["ApplicationIdentifierPrefix"] as? [String], !prefixes.isEmpty,
              let entitlements = payload["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              prefixes.contains(where: { !$0.isEmpty && !$0.contains(".") && appID == $0 + "." + expectedBundleID }),
              profile.bundleID == expectedBundleID,
              let creation = payload["CreationDate"] as? Date, creation <= now,
              profile.deviceUDIDs.contains(expectedUDID),
              (payload["ProvisionsAllDevices"] as? Bool) != true,
              let certificates = payload["DeveloperCertificates"] as? [Data],
              certificates.contains(expectedCertificateDER),
              Self.supports(entitlements: entitlements, team: expectedTeamID, appID: appID)
        else { throw ProfileValidationError.metadata }
        guard let expiry = LocSignVerifyProvisioningCertificate(expectedCertificateDER, privateKeyPEM, now) else {
            throw ProfileValidationError.certificate
        }
        guard profile.expiry > now else { throw ProfileValidationError.expired }
        return ValidatedProvisioningProfile(raw: data, signedContent: signedContent, profile: profile,
            uuid: uuid, certificateDER: expectedCertificateDER, certificateExpiry: expiry)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }

    private static func supports(entitlements: [String: Any], team: String, appID: String) -> Bool {
        let allowed: Set<String> = ["application-identifier", "com.apple.developer.team-identifier",
                                    "get-task-allow", "keychain-access-groups"]
        guard Set(entitlements.keys).isSubset(of: allowed),
              entitlements["get-task-allow"] as? Bool == true else { return false }
        if let value = entitlements["com.apple.developer.team-identifier"], value as? String != team { return false }
        if let value = entitlements["keychain-access-groups"] {
            guard let prefix = appID.split(separator: ".").first,
                  let groups = value as? [String], !groups.isEmpty,
                  groups.contains(where: { $0 == appID || $0 == "\(prefix).*" }),
                  groups.allSatisfy({ $0 == appID || $0 == "\(prefix).*" || $0 == "com.apple.token" }) else { return false }
        }
        return true
    }
}
