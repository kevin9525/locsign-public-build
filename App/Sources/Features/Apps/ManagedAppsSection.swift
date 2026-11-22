import SwiftUI

/// Signed apps on the signing page: LocSign itself first, then every app
/// installed through LocSign, sorted by expiry, each with one-tap renewal.
struct ManagedAppsSection: View {
    @ObservedObject var library: ManagedAppLibrary
    @ObservedObject var renewal: AppRenewalCoordinator
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var account: AppleIDProvisioningModel
    @ObservedObject var ownRenewal: SelfRenewalModel
    let background: RenewalBackgroundService
    @State private var message: String?
    @State private var removal: ManagedApp?
    @State private var selfRenewal: ManagedApp?
    @State private var importProfile: InstalledSelfProfile?
    @State private var operation: Task<Void, Never>?

    private var busy: Bool { settings.operationID != nil || account.isBusy || renewal.isRunning }

    private var otherApps: [ManagedApp] {
        let running = Bundle.main.bundleIdentifier
        return library.apps
            .filter { $0.identity.signingBundleID != running }
            .sorted { ($0.effectiveExpiry ?? .distantPast) < ($1.effectiveExpiry ?? .distantPast) }
    }

    /// The saved record that can renew LocSign itself without choosing the IPA again.
    private var managedSelf: ManagedApp? {
        guard let profile = ownRenewal.profile, library.loadError == nil else { return nil }
        let matches = library.apps.filter {
            $0.identity.signingBundleID == profile.bundleID && $0.identity.teamID == profile.teamID
                && profile.deviceUDIDs.contains($0.identity.deviceUDID)
                && (try? library.sourceURL(for: $0.id)) != nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var footerText: String {
        let automatic = renewal.enabled
            ? "已开启自动续签：到期前 48 小时尝试。"
            : "自动续签已关闭，可在“设置”中开启。"
        return "免费账号签名约 7 天有效，以 Apple 返回的描述文件为准。" + automatic + "长按 App 可清除记录。"
    }

    var body: some View {
        Section {
            selfRow
            ForEach(otherApps) { app in appRow(app) }
            if otherApps.isEmpty {
                Text("用 LocSign 安装过的 App 会出现在这里，到期前可一键续签。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if renewal.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text(renewal.stage).font(.subheadline)
                    ProgressView(value: renewal.progress)
                    Button("暂停续签", role: .cancel) { renewal.cancel() }
                }
            }
            if let error = library.loadError ?? message ?? renewal.error {
                Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            HStack {
                Text("已签名的 App")
                Spacer()
                if renewal.enabled && !otherApps.isEmpty {
                    Button("检查到期") {
                        operation = Task { _ = await renewal.runDue(); background.schedule(); operation = nil }
                    }
                    .font(.caption)
                    .disabled(busy)
                }
            }
        } footer: { Text(footerText) }
        .sheet(isPresented: Binding(
            get: { renewal.isRunning && !account.revocations.isEmpty },
            set: { if !$0 && renewal.isRunning { account.resolveRevocation(false) } }
        )) {
            RenewalCertificateDecisionView(account: account)
        }
        .sheet(item: $importProfile, onDismiss: { Task { await ownRenewal.refresh() } }) { profile in
            SelfRenewalSetupView(profile: profile, settings: settings, library: library, account: account)
        }
        .alert("清除本地记录与原 IPA？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("取消", role: .cancel) { removal = nil }
            Button("清除", role: .destructive) {
                guard let app = removal, !busy else { return }
                do { try library.remove(id: app.id); background.schedule() }
                catch { message = error.localizedDescription }
                removal = nil
            }
        } message: { Text("手机上的 App 会保留。之后如需续签，需要重新导入原 IPA。") }
        .alert("续签 LocSign 自身？", isPresented: Binding(get: { selfRenewal != nil }, set: { if !$0 { selfRenewal = nil } })) {
            Button("取消", role: .cancel) { selfRenewal = nil }
            Button("续签并安装") { if let app = selfRenewal { renew(app) }; selfRenewal = nil }
        } message: { Text("安装期间 LocSign 会退出。完成后重新打开，将核对自身的描述文件并更新续签记录。") }
    }

    // MARK: Rows

    @ViewBuilder private var selfRow: some View {
        if let profile = ownRenewal.profile {
            let needsRelaunch = library.selfInstallationNeedsRelaunch(bundleID: profile.bundleID)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label("LocSign", systemImage: "location.circle.fill").font(.headline)
                    Text("本 App")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Spacer()
                    expiryBadge(profile.profileExpiry)
                }
                if needsRelaunch {
                    Text(SelfInstallationAwaitingVerification.message).font(.caption).foregroundStyle(.orange)
                } else if profile.profileExpiry <= Date() {
                    Text("已到期。过期后通常无法打开，请在电脑用原 Apple ID 和原应用标识覆盖安装，不要先卸载。")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if let app = managedSelf {
                        Button("续签") { selfRenewal = app }.buttonStyle(.borderedProminent)
                    }
                    Button(managedSelf == nil ? "选择 LocSign IPA 续签" : "换 IPA 更新") { importProfile = profile }
                        .buttonStyle(.bordered)
                }
                .disabled(busy || needsRelaunch)
            }
            .padding(.vertical, 4)
            .contextMenu {
                if let app = managedSelf {
                    Button("清除记录", role: .destructive) { removal = app }
                }
            }
        } else if let error = ownRenewal.profileError {
            Text(error).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func appRow(_ app: ManagedApp) -> some View {
        let needsRelaunch = library.selfInstallationNeedsRelaunch(bundleID: app.identity.signingBundleID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(app.name, systemImage: "app.fill").font(.headline).lineLimit(1)
                Spacer()
                expiryBadge(app.effectiveExpiry)
            }
            Text(app.identity.signingBundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if app.pending?.awaitingRelaunchVerification == true {
                Text("重新打开后尚未确认本次更新，原有效期仍保留。可检查连接后重试。")
                    .font(.caption).foregroundStyle(.orange)
            } else if app.pending != nil {
                Text("上次安装尚未确认，原到期时间保持不变").font(.caption).foregroundStyle(.orange)
            }
            if let lastError = app.lastError {
                Text(lastError).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            HStack {
                Button("续签") { renew(app) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || needsRelaunch)
                Spacer()
                Toggle("自动续签", isOn: Binding(get: { app.autoRenew }, set: { value in
                    do { try library.setAutoRenew(id: app.id, enabled: value); background.schedule() }
                    catch { message = error.localizedDescription }
                }))
                .font(.caption)
                .fixedSize()
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { Button("清除记录", role: .destructive) { removal = app } }
    }

    @ViewBuilder private func expiryBadge(_ expiry: Date?) -> some View {
        if let expiry {
            let remaining = expiry.timeIntervalSinceNow
            Text(Self.expiryText(remaining))
                .font(.caption.weight(.semibold))
                .foregroundStyle(remaining <= 0 ? Color.red : (remaining <= 48 * 3600 ? Color.orange : Color.secondary))
        } else {
            Text("待确认").font(.caption).foregroundStyle(.orange)
        }
    }

    static func expiryText(_ remaining: TimeInterval) -> String {
        if remaining <= 0 { return "已过期" }
        let hours = Int(remaining / 3600)
        if hours < 24 { return "\(max(hours, 1)) 小时后到期" }
        return "\(hours / 24) 天后到期"
    }

    private func renew(_ app: ManagedApp) {
        guard !busy else { return }
        let minimum = app.identity.signingBundleID == ownRenewal.profile?.bundleID ? ownRenewal.profile?.profileExpiry : nil
        operation = Task {
            _ = await renewal.renew(id: app.id, minimumProfileExpiry: minimum)
            background.schedule()
            operation = nil
        }
    }
}

/// Self-renewal opens the signing flow in a sheet, preset to LocSign's own identity.
struct SelfRenewalSetupView: View {
    let settings: InstallationSettings
    let account: AppleIDProvisioningModel
    @StateObject private var signing: SigningViewModel

    init(profile: InstalledSelfProfile, settings: InstallationSettings, library: ManagedAppLibrary, account: AppleIDProvisioningModel) {
        self.settings = settings; self.account = account
        _signing = StateObject(wrappedValue: SigningViewModel(settings: settings, library: library, selfRenewalProfile: profile))
    }
    var body: some View { SigningView(settings: settings, model: signing, account: account) }
}

private struct RenewalCertificateDecisionView: View {
    @ObservedObject var account: AppleIDProvisioningModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("开发证书数量已达上限，需要撤销下列证书后才能申请新证书。撤销可能影响当前 LocSign 和使用这些证书签名的其他 App；后续申请或安装失败时，可能需要电脑重新覆盖安装。")
                        .foregroundStyle(.red)
                }
                Section("待撤销的证书") {
                    ForEach(account.revocations) { certificate in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(certificate.name).font(.headline)
                            Text("ID：\(certificate.id)")
                            Text("序列号：\(certificate.serialNumber)")
                            Text(certificate.expiry, format: .dateTime.year().month().day().hour().minute())
                        }.font(.footnote).textSelection(.enabled)
                    }
                }
                Section {
                    Button("保留证书并取消", role: .cancel) { account.resolveRevocation(false) }
                    Button("撤销列表中的全部证书并继续", role: .destructive) { account.resolveRevocation(true) }
                        .disabled(account.revocations.isEmpty)
                } footer: {
                    Text("确认后会再次核对 Apple 的证书列表。列表发生变化时停止，不按旧名单继续。")
                }
            }
            .navigationTitle("确认撤销开发证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { account.resolveRevocation(false) }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
