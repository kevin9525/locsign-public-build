import Foundation

/// Explains local eligibility, not an OS scheduling or Apple service promise.
enum AppRenewalStatus: Equatable {
    case pendingInstallation, pendingSelfVerification, notInstalled, missingSource
    case manualSelfRenewal, globallyDisabled, appDisabled, unknownExpiry
    case waiting(Date), ready

    static func evaluate(_ app: ManagedApp, enabled: Bool, sourceAvailable: Bool,
                         runningBundleID: String?, now: Date) -> Self {
        if let pending = app.pending {
            return pending.awaitingRelaunchVerification == true ? .pendingSelfVerification : .pendingInstallation
        }
        guard app.installedAt != nil else { return .notInstalled }
        guard app.sourceFile != nil, sourceAvailable else { return .missingSource }
        if app.identity.signingBundleID == runningBundleID { return .manualSelfRenewal }
        guard enabled else { return .globallyDisabled }
        guard app.autoRenew else { return .appDisabled }
        guard let expiry = app.effectiveExpiry else { return .unknownExpiry }
        let earliest = max(expiry.addingTimeInterval(-AppRenewalPolicy.renewalWindow), app.nextAttempt ?? .distantPast)
        return earliest > now ? .waiting(earliest) : .ready
    }

    var title: String {
        switch self {
        case .pendingInstallation: return "安装结果待确认"
        case .pendingSelfVerification: return "自身更新待核验"
        case .notInstalled: return "尚无确认安装记录"
        case .missingSource: return "需要原 IPA"
        case .manualSelfRenewal: return "LocSign 自身需手动续签"
        case .globallyDisabled: return "全局自动续签已关闭"
        case .appDisabled: return "此 App 自动续签已关闭"
        case .unknownExpiry: return "有效期尚未确认"
        case .waiting: return "等待自动续签条件"
        case .ready: return "已到自动续签尝试窗口"
        }
    }

    var guidance: String {
        switch self {
        case .pendingInstallation: return "上次安装未确认完成，原有效期仍保留。检查连接后，可手动续签重试。"
        case .pendingSelfVerification: return "完全关闭并重新打开 LocSign，核对新的描述文件。未核验前不会更新原有效期。"
        case .notInstalled: return "先用原 IPA 完成一次签名安装，才能纳入自动续签。"
        case .missingSource: return "请在签名页重新选择原 IPA，用原账号和应用标识安装一次。"
        case .manualSelfRenewal: return "自身覆盖安装会使 LocSign 退出；请手动续签，重新打开后核对结果。"
        case .globallyDisabled: return "可到“设置 → 续签”开启自动续签，也可随时手动续签。"
        case .appDisabled: return "可在签名页打开此 App 的自动续签开关，也可手动续签。"
        case .unknownExpiry: return "无法确定自动续签窗口，请先完成一次手动续签并确认安装结果。"
        case .waiting: return "到期前 48 小时开始尝试；失败后至少间隔 6 小时自动重试。手动续签不受此等待时间限制。"
        case .ready: return "本地时间条件已满足；仍需账号可用、配对正确和设备连接正常。可返回签名页检查到期，或手动续签。"
        }
    }
}
