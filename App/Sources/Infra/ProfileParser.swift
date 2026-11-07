import Foundation

struct ProvisioningProfileData {
    let raw: Data
    let payload: [String: Any]
    var bundleID: String {
        let entitlements = payload["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? ""
        // AppIdentifierPrefix can differ from TeamIdentifier for older accounts.
        guard let separator = appID.firstIndex(of: ".") else { return "" }
        return String(appID[appID.index(after: separator)...])
    }
    var teamID: String { (payload["TeamIdentifier"] as? [String])?.first ?? "" }
    var expiry: Date { payload["ExpirationDate"] as? Date ?? .distantPast }
    var deviceUDIDs: [String] { payload["ProvisionedDevices"] as? [String] ?? [] }
    var name: String { payload["Name"] as? String ?? "" }
    func permits(bundleIdentifier: String) -> Bool {
        if bundleID == "*" { return true }
        if bundleID.hasSuffix(".*") {
            return bundleIdentifier.hasPrefix(String(bundleID.dropLast()))
        }
        return bundleID == bundleIdentifier
    }
    func signingEntitlements(for identifier: String, restrictKeychainToApplication: Bool = false) throws -> Data {
        guard permits(bundleIdentifier: identifier),
              var entitlements = payload["Entitlements"] as? [String: Any],
              let applicationID = entitlements["application-identifier"] as? String,
              let prefix = applicationID.split(separator: ".").first else {
            throw LocSignError.signing("应用标识不在描述文件允许范围内")
        }
        let concreteID = "\(prefix).\(identifier)"
        entitlements["application-identifier"] = concreteID
        if let groups = entitlements["keychain-access-groups"] as? [String] {
            if restrictKeychainToApplication {
                guard groups.contains(concreteID) || groups.contains("\(prefix).*") else {
                    throw LocSignError.signing("描述文件未授权当前应用的钥匙串组")
                }
                // Profile entries authorize claims; they are not a list of
                // claims the App needs. Never claim Apple/shared groups here.
                entitlements["keychain-access-groups"] = [concreteID]
            } else {
                entitlements["keychain-access-groups"] = groups.map { group in
                    group == "\(prefix).*" ? concreteID : group
                }
            }
        }
        return try PlistCodec.encodeXML(entitlements)
    }
    /// 从 Entitlements 字段生成签名用 entitlements XML——保证与描述文件一致（Review Focus 3）
    var entitlementsXML: String {
        let ents = payload["Entitlements"] as? [String: Any] ?? [:]
        return (try? PlistCodec.encodeXML(ents)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

enum ProfileParser {
    static func parse(_ mobileprovision: Data) throws -> ProvisioningProfileData {
        // Metadata extraction only; this does not authenticate Apple's CMS signature.
        let slice = try payloadData(from: mobileprovision)
        let payload = try PlistCodec.decode(slice) as? [String: Any]
        guard let payload else { throw LocSignError.infra("描述文件 payload 非 dict") }
        let profile = ProvisioningProfileData(raw: mobileprovision, payload: payload)
        guard !profile.teamID.isEmpty, !profile.bundleID.isEmpty else {
            throw LocSignError.provisioning("描述文件缺少 TeamIdentifier 或 Entitlements.application-identifier")
        }
        return profile
    }

    static func payloadData(from mobileprovision: Data) throws -> Data {
        guard let range = mobileprovision.range(of: Data("<?xml".utf8)),
              let end = mobileprovision.range(of: Data("</plist>".utf8),
                                             in: range.lowerBound..<mobileprovision.endIndex)
        else { throw LocSignError.infra("描述文件中未找到 plist payload") }
        return mobileprovision.subdata(in: range.lowerBound..<end.upperBound)
    }
}
