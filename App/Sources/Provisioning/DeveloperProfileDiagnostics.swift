import Foundation

enum DeveloperProfileReason: Sendable, Equatable {
    case nameConflict, existingProfile, profileLimit, certificate, device, bundle, profileType, unknown

    var message: String {
        switch self {
        case .nameConflict: return "描述文件名称已存在（P01），更名后仍被拒绝，请保留现有材料并稍后重试"
        case .existingProfile: return "此应用已有描述文件（P02），Apple 不允许直接创建另一个；尚未找到可复用的有效文件，旧文件已保留"
        case .profileLimit: return "描述文件数量已达 Apple 限制（P03），更换名称不能解除限制；现有材料已保留"
        case .certificate: return "Apple 不接受此描述文件关联的开发证书（P04），请确认所选团队和证书状态"
        case .device: return "Apple 不接受此描述文件关联的设备（P05），请确认设备在所选团队中可用"
        case .bundle: return "Apple 不接受此描述文件关联的应用标识（P06），请保持原团队及个人签名标识并检查其状态"
        case .profileType: return "Apple 不接受当前开发描述文件类型（P07），请确认团队支持 iOS 开发签名"
        case .unknown: return "描述文件创建冲突（P00），Apple 返回了未识别的原因；现有材料已保留，请反馈此错误码"
        }
    }
}

enum DeveloperProfileDiagnostics {
    /// Only closed categories leave this parser. Never retain a response, name,
    /// identifier, arbitrary code, or echoed server value in an error/log.
    static func rejection(status: Int, data: Data) -> DeveloperServicesError? {
        guard status == 409, data.count <= 65_536,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]], !errors.isEmpty, errors.count <= 20 else { return nil }
        let reasons = errors.map(classify)
        // Retrying a POST is allowed only when every returned error explicitly
        // rejects the name. A mixed or unknown error never authorizes a retry.
        if reasons.allSatisfy({ $0 == .nameConflict }) { return .profileRejected(status, .nameConflict) }
        let priority: [DeveloperProfileReason] = [.profileLimit, .existingProfile, .certificate, .device, .bundle, .profileType]
        return .profileRejected(status, priority.first(where: { reasons.contains($0) }) ?? .unknown)
    }

    private static func classify(_ error: [String: Any]) -> DeveloperProfileReason {
        let detail = (error["detail"] as? String ?? "").lowercased()
        guard detail.utf8.count <= 4096 else { return .unknown }
        let pointer = (error["source"] as? [String: Any])?["pointer"] as? String ?? ""
        func matches(_ pattern: String) -> Bool { detail.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"^(?:you have reached (?:the )?(?:maximum number|limit) of (?:provisioning )?profiles\b|you may (?:create|register) a maximum of [0-9]+ (?:provisioning )?profiles\b)"#) {
            return .profileLimit
        }
        if matches(#"^there is already a current (?:ios )?(?:app )?development (?:provisioning )?profile for this app id(?:\.|$)"#) {
            return .existingProfile
        }
        if pointer == "/data/attributes/name", error["code"] as? String == "ENTITY_ERROR.ATTRIBUTE.INVALID",
           matches(#"^(?:a (?:provisioning )?profile with (?:the )?name '[^'\r\n]+' already exists(?: on this team)?\.?|a (?:provisioning )?profile with (?:the )?name \"[^\"\r\n]+\" already exists(?: on this team)?\.?)$"#) {
            return .nameConflict
        }
        let relationships: [(String, DeveloperProfileReason)] = [
            ("/data/relationships/certificates", .certificate),
            ("/data/relationships/devices", .device),
            ("/data/relationships/bundleId", .bundle)
        ]
        for (path, reason) in relationships where pointer == path || pointer.hasPrefix(path + "/") { return reason }
        if pointer == "/data/attributes/profileType" { return .profileType }
        return .unknown
    }
}
