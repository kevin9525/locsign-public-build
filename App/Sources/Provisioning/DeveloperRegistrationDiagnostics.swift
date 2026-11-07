import Foundation

enum DeveloperRegistrationReason: Sendable, Equatable {
    case identifierUnavailable, registrationLimit, invalidAttribute

    var message: String {
        switch self {
        case .identifierUnavailable: return "应用标识不可用，请选择个人签名标识后重试"
        case .registrationLimit: return "应用标识注册数量已达限制，请等待 Apple 的注册额度恢复；更换标识不能解除限制"
        case .invalidAttribute: return "应用标识注册字段不符合 Apple 要求，请检查标识和应用名称"
        }
    }
}

enum DeveloperRegistrationDiagnostics {
    // Inspect bounded data in memory. Only closed categories leave this parser;
    // neither server messages nor arbitrary error codes are retained.
    static func rejection(status: Int, data: Data) -> DeveloperServicesError? {
        guard status == 409, data.count <= 65_536,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = payload["errors"] as? [[String: Any]], !errors.isEmpty, errors.count <= 20 else { return nil }
        var reasons: [DeveloperRegistrationReason] = []
        for error in errors {
            let detail = (error["detail"] as? String ?? "").lowercased()
            guard detail.utf8.count <= 4096 else { continue }
            let isAppID = detail.contains("app id") || detail.contains("app ids") || detail.contains("bundle identifier")
            // Never infer quotas from words inside an echoed bundle identifier.
            if detail.range(of: #"^(?:you may register a maximum of [0-9]+ app ids\b|you have reached (?:the )?(?:maximum number|limit) of app ids\b)"#,
                            options: .regularExpression) != nil {
                reasons.append(.registrationLimit)
            } else if isAppID && (detail.contains("not available") || detail.contains("already in use") ||
                                   detail.contains("already exists")) {
                reasons.append(.identifierUnavailable)
            } else if error["code"] as? String == "ENTITY_ERROR.ATTRIBUTE.INVALID" {
                reasons.append(.invalidAttribute)
            }
        }
        // A quota must not be hidden by another error suggesting an ID change.
        let reason = reasons.contains(.registrationLimit) ? .registrationLimit : reasons.first
        return reason.map { .registrationRejected(status, $0) }
    }
}
