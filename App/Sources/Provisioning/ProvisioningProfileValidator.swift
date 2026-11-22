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
        case .metadata: return "描述文件与所选团队、应用或设备不匹配，或包含不支持的权限（具体原因见“文件 → 我的 iPhone → LocSign → logs → app.log”）"
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
        } catch {
            AppLogger.log(.warn, "ProfileValidator", "描述文件未通过校验（期望应用 \(expectedBundleID)）：签名内容与描述文件正文不一致或无法解析")
            throw ProfileValidationError.metadata
        }
        let payload = profile.payload
        // Each check names its reason in the log so a rejected profile can be
        // diagnosed on device. Only identifiers and key names are logged.
        func reject(_ reason: String) -> ProfileValidationError {
            AppLogger.log(.warn, "ProfileValidator", "描述文件未通过校验（期望应用 \(expectedBundleID)）：\(reason)")
            return .metadata
        }
        guard !expectedBundleID.isEmpty, !expectedTeamID.isEmpty, !expectedUDID.isEmpty,
              !expectedBundleID.contains("*") else { throw reject("期望的应用、团队或设备为空，或应用标识含通配符") }
        guard let uuid = payload["UUID"] as? String, UUID(uuidString: uuid) != nil else { throw reject("缺少有效 UUID") }
        guard let teams = payload["TeamIdentifier"] as? [String], teams == [expectedTeamID] else {
            throw reject("团队不一致（描述文件 \((payload["TeamIdentifier"] as? [String])?.joined(separator: ",") ?? "无")）")
        }
        guard let prefixes = payload["ApplicationIdentifierPrefix"] as? [String], !prefixes.isEmpty,
              let entitlements = payload["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String else {
            throw reject("缺少应用标识前缀或 application-identifier")
        }
        guard prefixes.contains(where: { !$0.isEmpty && !$0.contains(".") && appID == $0 + "." + expectedBundleID }),
              profile.bundleID == expectedBundleID else {
            throw reject("应用标识不一致（描述文件 \(profile.bundleID)）")
        }
        // Apple stamps CreationDate with server time; a freshly created profile
        // can be slightly ahead of this device's clock.
        guard let creation = payload["CreationDate"] as? Date,
              creation <= now.addingTimeInterval(Self.clockTolerance) else {
            let ahead = (payload["CreationDate"] as? Date).map { Int($0.timeIntervalSince(now)) }
            throw reject("创建时间晚于本机时间\(ahead.map { " \($0) 秒" } ?? "（缺少创建时间）")，请检查手机日期与时间是否设为自动")
        }
        guard profile.deviceUDIDs.contains(expectedUDID) else { throw reject("未包含本机设备") }
        guard (payload["ProvisionsAllDevices"] as? Bool) != true else { throw reject("描述文件对所有设备生效，不是开发描述文件") }
        guard let certificates = payload["DeveloperCertificates"] as? [Data],
              certificates.contains(expectedCertificateDER) else { throw reject("当前开发证书不在描述文件中") }
        if let problem = Self.entitlementProblem(entitlements, team: expectedTeamID, appID: appID) {
            throw reject(problem)
        }
        guard let expiry = LocSignVerifyProvisioningCertificate(expectedCertificateDER, privateKeyPEM, now) else {
            throw ProfileValidationError.certificate
        }
        guard profile.expiry > now else { throw ProfileValidationError.expired }
        return ValidatedProvisioningProfile(raw: data, signedContent: signedContent, profile: profile,
            uuid: uuid, certificateDER: expectedCertificateDER, certificateExpiry: expiry)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }

    /// Allowed difference between Apple's CreationDate and this device's clock.
    static let clockTolerance: TimeInterval = 600

    /// Nil when every entitlement is supported; otherwise a reason naming the key.
    private static func entitlementProblem(_ entitlements: [String: Any], team: String, appID: String) -> String? {
        let unknown = Set(entitlements.keys).subtracting(allowedEntitlements).sorted()
        if !unknown.isEmpty { return "包含暂不支持的权限：" + unknown.joined(separator: ", ") }
        return checkedEntitlements(entitlements, team: team, appID: appID) ? nil : "权限取值不支持（get-task-allow、钥匙串组、App Groups 或团队标识）"
    }

    private static let allowedEntitlements: Set<String> = ["application-identifier", "com.apple.developer.team-identifier",
                                                           "get-task-allow", "keychain-access-groups",
                                                           "com.apple.security.application-groups",
                                                           "com.apple.developer.kernel.increased-memory-limit"]

    private static func checkedEntitlements(_ entitlements: [String: Any], team: String, appID: String) -> Bool {
        guard Set(entitlements.keys).isSubset(of: allowedEntitlements),
              entitlements["get-task-allow"] as? Bool == true else { return false }
        // These are profile authorizations, not required executable claims.
        // Accept only their known shapes; automatic signing does not claim them.
        if let value = entitlements["com.apple.security.application-groups"] {
            guard let groups = value as? [String], groups.allSatisfy({
                $0.range(of: #"^group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$"#, options: .regularExpression) != nil
            }) else { return false }
        }
        if let value = entitlements["com.apple.developer.kernel.increased-memory-limit"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        }
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
