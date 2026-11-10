import Foundation

enum DeveloperProfileReason: Sendable, Equatable {
    case nameConflict, existingProfile, profileLimit, certificate, device, bundle, profileType, unknown
    case unknownWithEvidence([DeveloperProfileEvidence])

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
        case .unknownWithEvidence(let evidence):
            return DeveloperProfileReason.unknown.message + "；诊断线索（不代表已确定原因）：" + evidence.map(\.rawValue).joined(separator: "，")
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
        if let reason = priority.first(where: { reasons.contains($0) }) { return .profileRejected(status, reason) }
        var evidence: [DeveloperProfileEvidence] = []
        for error in errors {
            for hint in DeveloperProfileEvidence.collect(error) where !evidence.contains(hint) { evidence.append(hint) }
        }
        return .profileRejected(status, evidence.isEmpty ? .unknown : .unknownWithEvidence(evidence))
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

// Only closed labels can leave the parser, including for unknown conflicts.
// Evidence is explanatory only; it must never authorize a mutation or retry.
enum DeveloperProfileEvidence: String, Sendable, Equatable {
    case entity = "Apple ENTITY_ERROR"
    case invalidAttribute = "Apple ENTITY_ERROR.ATTRIBUTE.INVALID"
    case invalidRelationship = "Apple ENTITY_ERROR.RELATIONSHIP.INVALID"
    case requiredAttribute = "Apple ENTITY_ERROR.ATTRIBUTE.REQUIRED"
    case requiredRelationship = "Apple ENTITY_ERROR.RELATIONSHIP.REQUIRED"
    case forbidden = "Apple FORBIDDEN_ERROR"
    case invalidParameter = "Apple PARAMETER_ERROR.INVALID"
    case nameField = "字段：名称", typeField = "字段：类型"
    case duplicate = "关键词：重复", name = "关键词：名称", limit = "关键词：限额"
    case certificate = "关键词：证书", device = "关键词：设备", bundle = "关键词：应用标识"
    case permission = "关键词：许可", expired = "关键词：过期", invalid = "关键词：无效"
    case capability = "关键词：权限能力", profileType = "关键词：类型"

    fileprivate static func collect(_ error: [String: Any]) -> [Self] {
        let knownCodes: [String: Self] = [
            "ENTITY_ERROR": .entity, "ENTITY_ERROR.ATTRIBUTE.INVALID": .invalidAttribute,
            "ENTITY_ERROR.RELATIONSHIP.INVALID": .invalidRelationship,
            "ENTITY_ERROR.ATTRIBUTE.REQUIRED": .requiredAttribute,
            "ENTITY_ERROR.RELATIONSHIP.REQUIRED": .requiredRelationship,
            "FORBIDDEN_ERROR": .forbidden, "PARAMETER_ERROR.INVALID": .invalidParameter
        ]
        var result: [Self] = []
        if let code = error["code"] as? String, let hint = knownCodes[code] { result.append(hint) }
        if let pointer = (error["source"] as? [String: Any])?["pointer"] as? String {
            if pointer == "/data/attributes/name" { result.append(.nameField) }
            if pointer == "/data/attributes/profileType" { result.append(.typeField) }
        }
        guard let detail = error["detail"] as? String, detail.utf8.count <= 4096 else { return result }
        // Discard quoted values (also an unfinished quote), then match complete
        // words. Emails, URLs and compound identifiers cannot supply keywords.
        var unquoted = ""
        var closingQuote: Character?
        let quotes: [Character: Character] = ["'": "'", "\"": "\"", "“": "”", "‘": "’"]
        for character in detail {
            if let closing = closingQuote {
                if character == closing { closingQuote = nil; unquoted.append(" ") }
            } else if let closing = quotes[character] {
                closingQuote = closing
                unquoted.append(" ")
            } else { unquoted.append(character) }
        }
        let punctuation = CharacterSet(charactersIn: ".,;:!?()[]{}")
        let words = Set(unquoted.lowercased().split(whereSeparator: { $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: punctuation)
        })
        let hints: [(Self, Set<String>)] = [
            (.duplicate, ["duplicate", "duplicates", "multiple"]), (.name, ["name", "names", "named"]),
            (.limit, ["limit", "maximum", "quota"]), (.certificate, ["certificate", "certificates"]),
            (.device, ["device", "devices"]), (.bundle, ["bundle", "identifier", "identifiers"]),
            (.permission, ["allowed", "permitted", "permission", "permissions", "forbidden"]),
            (.expired, ["expired", "expiration"]), (.invalid, ["invalid"]),
            (.capability, ["capability", "capabilities", "entitlement", "entitlements"]), (.profileType, ["type", "platform"])
        ]
        for (hint, keywords) in hints where !words.isDisjoint(with: keywords) { result.append(hint) }
        return result
    }
}
