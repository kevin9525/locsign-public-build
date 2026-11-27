import SwiftUI

struct ManagedAppDetailView: View {
    let appID: UUID
    @ObservedObject var library: ManagedAppLibrary
    @ObservedObject var renewal: AppRenewalCoordinator
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var account: AppleIDProvisioningModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                if let app = library.apps.first(where: { $0.id == appID }) {
                    details(app, now: context.date)
                } else {
                    ContentUnavailableView("记录已移除", systemImage: "app.dashed",
                                           description: Text("返回签名页查看当前已签名 App。"))
                }
            }
        }
        .navigationTitle("续签详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func details(_ app: ManagedApp, now: Date) -> some View {
        let sourceAvailable = (try? library.sourceURL(for: app.id)) != nil
        let status = AppRenewalStatus.evaluate(app, enabled: renewal.enabled, sourceAvailable: sourceAvailable,
                                             runningBundleID: Bundle.main.bundleIdentifier, now: now)
        Section("应用") {
            LabeledContent("名称", value: app.name)
            LabeledContent("签名标识", value: app.identity.signingBundleID).textSelection(.enabled)
            dateRow("已确认记录有效期至", app.effectiveExpiry)
            dateRow("描述文件有效期至", app.profileExpiry)
            dateRow("证书有效期至", app.certificateExpiry)
            LabeledContent("原 IPA", value: sourceAvailable ? "已保存" : "不可用")
        }
        Section {
            Text(status.title).font(.headline)
            Text(status.guidance).font(.footnote).foregroundStyle(.secondary)
            if case .waiting(let date) = status { dateRow("最早自动尝试时间", date) }
            if let next = app.nextAttempt, next > now { dateRow("自动重试冷却至", next) }
        } header: { Text("自动续签状态") } footer: {
            Text("时间表示本地允许尝试的最早时间。后台执行由 iOS 安排，打开 App 时会补做；并非保证执行时间。")
        }
        Section("最近记录") {
            dateRow("上次确认安装", app.installedAt)
            dateRow("上次续签尝试", app.lastAttempt)
            if let error = app.lastError {
                Text(ProvisioningRedaction.redact(error)).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text("没有已记录的失败原因").foregroundStyle(.secondary)
            }
        }
        Section {
            if account.requiresLogin || account.account == nil {
                Text("当前账号未登录或登录已失效，请到“设置 → Apple ID 与签名设置”处理。")
            } else if let identity = account.account,
                      ProvisioningKeychain.normalize(identity.appleID) != app.identity.appleID ||
                      !identity.teams.contains(where: { $0.id == app.identity.teamID }) {
                Text("当前账号与此 App 原签名账号或团队不匹配，请到设置切回原账号。")
            }
            if settings.pairing == nil { Text("尚未导入配对文件，请到签名页完成准备。") }
            Text("需要立即重试时，返回签名页点此 App 的“续签”。")
            NavigationLink("连接自检") { ConnectionView(settings: settings) }
            NavigationLink("诊断日志") { DiagnosticLogsView() }
        } header: { Text("处理与排查") }
    }

    private func dateRow(_ title: String, _ date: Date?) -> some View {
        LabeledContent(title) {
            if let date { Text(date, format: .dateTime.year().month().day().hour().minute()) }
            else { Text("暂无记录").foregroundStyle(.secondary) }
        }
    }
}
