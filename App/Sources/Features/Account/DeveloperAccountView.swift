import SwiftUI

/// Apple ID certificate management: development certificates (revocable),
/// App IDs with their profiles, registered devices and the estimated free
/// App ID allowance. Pushed from the App page and the Apple ID sheet.
struct DeveloperAccountView: View {
    @ObservedObject var account: AppleIDProvisioningModel
    @StateObject private var model: DeveloperAccountModel
    private let blocked: Bool
    @State private var pendingRevocation: DeveloperCertificateSummary?
    @State private var refresh: Task<Void, Never>?

    init(account: AppleIDProvisioningModel, blocked: Bool = false) {
        self.account = account
        self.blocked = blocked
        _model = StateObject(wrappedValue: DeveloperAccountModel(account: account))
    }

    private var disabled: Bool { blocked || account.isBusy || model.isBusy || model.unavailableReason != nil }

    var body: some View {
        List {
            if let reason = model.unavailableReason {
                Section { Text(reason).foregroundStyle(.secondary) }
            }
            if let identity = account.account {
                Section("账号") {
                    LabeledContent("Apple ID", value: identity.appleID)
                    if let team = identity.teams.first(where: { $0.id == account.teamID }) {
                        LabeledContent("团队", value: "\(team.name)（\(team.id)）")
                    }
                }
            }
            if blocked {
                Section { Text("正在安装、续签或登录，完成后再刷新。").foregroundStyle(.orange) }
            }
            if let overview = model.overview { content(overview) }
            if model.isLoading {
                Section { HStack { ProgressView(); Text("正在读取 Apple 开发者账号…") } }
            }
            if let notice = model.notice {
                Section { Text(notice).foregroundStyle(.green).textSelection(.enabled) }
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle("证书与 App ID")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.revokingID != nil)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(disabled)
            }
        }
        .refreshable { if !disabled { await model.load() } }
        .task { if !blocked { await model.load() } }
        .onChange(of: account.teamID) { _, _ in
            model.reset()
            reload()
        }
        .onDisappear {
            refresh?.cancel()
            refresh = nil
        }
        .confirmationDialog("撤销开发证书？",
                            isPresented: Binding(get: { pendingRevocation != nil },
                                                 set: { if !$0 { pendingRevocation = nil } }),
                            titleVisibility: .visible, presenting: pendingRevocation) { item in
            Button("撤销", role: .destructive) {
                pendingRevocation = nil
                Task { await model.revoke(item) }
            }
            Button("取消", role: .cancel) { pendingRevocation = nil }
        } message: { item in
            Text(item.usedByLocSign
                 ? "这是 LocSign 当前保存的签名证书。撤销后，用它签名的 App（如果 LocSign 自身是用它续签的，也包括 LocSign）会无法打开；LocSign 下次安装时会申请新证书。此操作无法恢复。"
                 : "撤销后，用此证书签名的 App 会无法打开，需要重新签名安装。此操作无法恢复。")
        }
    }

    private func reload() {
        guard !disabled, refresh == nil else { return }
        refresh = Task {
            await model.load()
            refresh = nil
        }
    }

    @ViewBuilder
    private func content(_ overview: DeveloperAccountOverview) -> some View {
        Section {
            LabeledContent("App ID 总数", value: "\(overview.appIDs.count)")
            LabeledContent("近 7 天已用（估算）",
                           value: "\(overview.recentAppIDEstimate) / \(DeveloperAccountOverview.freeAppIDLimit)")
            LabeledContent("剩余（估算）", value: "\(overview.estimatedRemainingAppIDs)")
        } header: { Text("App ID 额度（免费账号）") } footer: {
            Text("免费账号每 7 天最多注册 10 个 App ID，带扩展的 App 每个扩展另占 1 个。Apple 不提供 App ID 的注册时间，这里按 7 天内新建过描述文件的 App ID 估算，仅供参考，以 Apple 实际返回为准。付费开发者账号不受此限制。")
        }
        Section {
            if overview.certificates.isEmpty { Text("没有开发证书").foregroundStyle(.secondary) }
            ForEach(overview.certificates) { item in certificateRow(item, now: overview.loadedAt) }
        } header: { Text("开发证书（\(overview.certificates.count)）") } footer: {
            Text("证书数量达到上限时无法申请新证书。撤销后，用该证书签名的 App 会无法打开，需要重新签名安装；撤销无法恢复。撤销前会重新核对 Apple 的证书列表，有变化就停止。")
        }
        Section {
            if overview.appIDs.isEmpty { Text("没有 App ID").foregroundStyle(.secondary) }
            ForEach(overview.appIDs) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.headline)
                    Text(app.identifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if app.profiles.isEmpty {
                        Text("没有描述文件").font(.caption).foregroundStyle(.secondary)
                    } else if let expiry = app.latestProfileExpiry {
                        HStack(spacing: 4) {
                            Text("描述文件 \(app.profiles.count) 个，最晚")
                            Text(expiry, format: .dateTime.year().month().day().hour().minute())
                            Text(expiry <= overview.loadedAt ? "已到期" : "到期")
                        }.font(.caption).foregroundStyle(expiry <= overview.loadedAt ? .red : .secondary)
                    } else {
                        Text("描述文件 \(app.profiles.count) 个").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 2)
            }
        } header: { Text("App ID（\(overview.appIDs.count)）") } footer: {
            Text("只读列表。LocSign 不会删除 App ID 或描述文件；删除 App ID 也不会退回本周额度。")
        }
        Section {
            if overview.devices.isEmpty { Text("没有已注册设备").foregroundStyle(.secondary) }
            ForEach(overview.devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.name).font(.headline)
                        Spacer()
                        if !device.enabled { Text("已停用").font(.caption).foregroundStyle(.orange) }
                    }
                    Text([device.model, "UDID \(device.maskedUDID)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 2)
            }
        } header: { Text("已注册设备（\(overview.devices.count)）") } footer: {
            Text("UDID 只显示末 6 位。")
        }
        Section {
            HStack(spacing: 4) {
                Text("更新于")
                Text(overview.loadedAt, format: .dateTime.month().day().hour().minute().second())
            }.font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func certificateRow(_ item: DeveloperCertificateSummary, now: Date) -> some View {
        let certificate = item.certificate
        let expired = certificate.expiry <= now
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(certificate.name).font(.headline)
                Spacer()
                if item.usedByLocSign { Text("LocSign 使用中").font(.caption).foregroundStyle(.blue) }
            }
            Text("序列号：\(certificate.serialNumber)").font(.caption).textSelection(.enabled)
            HStack(spacing: 4) {
                Text(expired ? "已过期" : "有效期至")
                Text(certificate.expiry, format: .dateTime.year().month().day().hour().minute())
            }.font(.caption).foregroundStyle(expired ? .red : .secondary)
            Button(model.revokingID == certificate.id ? "正在撤销…" : "撤销此证书", role: .destructive) {
                pendingRevocation = item
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
        }.padding(.vertical, 2)
    }
}
