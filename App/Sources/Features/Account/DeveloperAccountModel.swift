import Foundation
import Combine

/// State for the certificate management page. Every Apple request goes
/// through the shared provisioning engine, so it never runs alongside an
/// install, renewal or login started elsewhere in the app.
@MainActor
final class DeveloperAccountModel: ObservableObject {
    @Published private(set) var overview: DeveloperAccountOverview?
    @Published private(set) var isLoading = false
    @Published private(set) var revokingID: String?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private let account: AppleIDProvisioningModel
    private var generation = UUID()

    init(account: AppleIDProvisioningModel) { self.account = account }

    var isBusy: Bool { isLoading || revokingID != nil }

    var unavailableReason: String? {
        guard account.account != nil else { return "请先在“Apple ID 与签名设置”中登录 Apple ID。" }
        if account.requiresLogin { return "Apple ID 登录已过期，请重新登录后再查看。" }
        if account.teamID.isEmpty { return "请先在“Apple ID 与签名设置”中选择团队。" }
        if !account.providerEnabled || !account.providerAccepted { return "请先启用并确认 Anisette 提供方。" }
        if account.engine == nil { return "Apple ID 服务尚未就绪，请稍后刷新。" }
        return nil
    }

    func reset() {
        generation = UUID()
        overview = nil
        error = nil
        notice = nil
        isLoading = false
    }

    func load() async { await load(keepingMessages: false) }

    private func load(keepingMessages: Bool) async {
        guard !isBusy, !account.isBusy, unavailableReason == nil,
              let identity = account.account, let engine = account.engine else { return }
        let teamID = account.teamID
        let operation = UUID()
        generation = operation
        isLoading = true
        if !keepingMessages { error = nil; notice = nil }
        defer { if generation == operation { isLoading = false } }
        do {
            let value = try await engine.accountOverview(accountID: identity.id, teamID: teamID)
            guard generation == operation, account.account?.id == identity.id, account.teamID == teamID else { return }
            overview = value
        } catch {
            guard generation == operation else { return }
            handle(error)
        }
    }

    func revoke(_ item: DeveloperCertificateSummary) async {
        guard !isBusy, !account.isBusy, unavailableReason == nil,
              let identity = account.account, let engine = account.engine else { return }
        let teamID = account.teamID
        let operation = UUID()
        generation = operation
        revokingID = item.id
        error = nil
        notice = nil
        do {
            try await engine.revokeCertificate(item.certificate, accountID: identity.id, teamID: teamID)
            if generation == operation {
                notice = "已撤销证书 \(item.certificate.name)（序列号 \(item.certificate.serialNumber)）。用它签名的 App 需要重新签名安装。"
            }
        } catch {
            if generation == operation { handle(error) }
        }
        guard generation == operation else { return }
        revokingID = nil
        // Always re-read: Apple may have finished the revocation even if the
        // response was lost, and a changed list must be shown before any retry.
        await load(keepingMessages: true)
    }

    private func handle(_ error: Error) {
        if (error as? ProvisioningError) == .invalidAccount { account.requireLogin() }
        self.error = Self.message(error)
    }

    nonisolated static func message(_ error: Error) -> String {
        if error is CancellationError || (error as? ProvisioningError) == .cancelled { return "操作已取消" }
        if (error as? DeveloperServicesError) == .remoteChanged {
            return "Apple 的证书列表已变化，未撤销任何证书。请刷新后重新确认。"
        }
        return ProvisioningRedaction.redact(error.localizedDescription)
    }
}
