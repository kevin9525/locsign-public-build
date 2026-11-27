import SwiftUI

/// Settings tab: account, renewal switches, device tools and about. Features
/// that are not part of the main sign-and-locate flow live here.
struct SettingsView: View {
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var account: AppleIDProvisioningModel
    @ObservedObject var signing: SigningViewModel
    @ObservedObject var renewal: AppRenewalCoordinator
    @ObservedObject var ownRenewal: SelfRenewalModel
    @ObservedObject var library: ManagedAppLibrary
    let background: RenewalBackgroundService
    @State private var showingAppleID = false
    @State private var confirmingClearPairing = false
    @State private var message: String?

    private var busy: Bool { settings.operationID != nil || account.isBusy || renewal.isRunning || signing.busy }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version)（\(build)）"
    }

    private var pairingFooter: String {
        if let pairing = settings.pairing { return "配对文件：\(pairing.name)。签名安装与定位共用。" }
        return "尚未导入配对文件，可在“签名”页的“准备”中导入。"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingAppleID = true } label: {
                        HStack {
                            Label("Apple ID 与签名设置", systemImage: "person.crop.circle")
                            Spacer()
                            Text(account.account?.appleID ?? "未登录").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .disabled(busy)
                    NavigationLink {
                        DeveloperAccountView(account: account, blocked: busy)
                    } label: {
                        Label("证书与 App ID 管理", systemImage: "checkmark.seal")
                    }
                    .disabled(busy)
                } header: { Text("账号") } footer: {
                    Text("登录、团队、Anisette 提供方和个人签名标识在“Apple ID 与签名设置”中修改。")
                }

                Section {
                    Toggle(isOn: $renewal.enabled) { Label("自动续签", systemImage: "arrow.clockwise") }
                        .onChange(of: renewal.enabled) { _, _ in
                            background.schedule()
                            Task { await background.requestNotificationsIfNeeded() }
                        }
                    Toggle(isOn: Binding(get: { ownRenewal.remindersEnabled }, set: { enabled in
                        Task { await ownRenewal.setRemindersEnabled(enabled) }
                    })) { Label("LocSign 到期提醒", systemImage: "bell") }
                    Button {
                        Task {
                            let allowed = await background.requestNotifications()
                            message = allowed ? "已允许续签失败通知" : "通知未开启，可到 iOS 设置中允许 LocSign 通知"
                        }
                    } label: { Label("开启续签失败通知", systemImage: "bell.badge") }
                    if let error = ownRenewal.notificationError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                } header: { Text("续签") } footer: {
                    Text("自动续签在到期前 48 小时尝试，后台由 iOS 安排，打开 LocSign 时补做；失败后至少间隔 6 小时重试。LocSign 自身需在“签名”页手动续签，提醒在到期前 48 和 24 小时发出。")
                }

                Section {
                    NavigationLink {
                        ConnectionView(settings: settings)
                    } label: { Label("连接自检", systemImage: "cable.connector") }
                    NavigationLink {
                        DeviceAppsView(settings: settings, library: library)
                    } label: { Label("设备上的 App", systemImage: "square.grid.2x2") }
                    if settings.pairing != nil {
                        Button(role: .destructive) { confirmingClearPairing = true } label: {
                            Label("清除保存的配对文件", systemImage: "trash")
                        }
                        .disabled(busy)
                    }
                } header: { Text("设备") } footer: { Text(pairingFooter) }

                Section("关于") {
                    LabeledContent("版本", value: versionText)
                    NavigationLink {
                        DiagnosticLogsView()
                    } label: { Label("诊断日志", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink("第三方许可") { ThirdPartyLicensesView() }
                }

                if let message {
                    Section { Text(message).textSelection(.enabled) }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingAppleID) {
                AppleIDProvisioningSheet(account: account, signing: signing)
            }
            .alert("清除保存的配对文件？", isPresented: $confirmingClearPairing) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    do { try settings.clearPairing(); message = nil }
                    catch { message = error.localizedDescription }
                }
            } message: { Text("清除后，签名安装和定位都需要重新导入配对文件。") }
        }
    }
}

/// Read-only list of user apps installed on the paired device.
struct DeviceAppsView: View {
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var library: ManagedAppLibrary
    @State private var deviceApps: InstalledAppList?
    @State private var loading = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Button(loading ? "正在读取设备 App…" : "读取已安装 App 列表", action: browse)
                    .disabled(loading || settings.operationID != nil || settings.pairing == nil)
                if let deviceApps {
                    ForEach(deviceApps.apps) { app in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(app.name); Spacer(); Text(app.version).foregroundStyle(.secondary) }
                            Text(app.id).font(.caption).foregroundStyle(.secondary)
                            if !library.apps.contains(where: { $0.identity.deviceUDID == deviceApps.deviceUDID && $0.identity.signingBundleID == app.id }) {
                                Text("如需续签，请选择原 IPA，用 LocSign 安装一次。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("只读取用户安装的 App，系统 App 不在列表中。")
            }
            if let message {
                Section { Text(message).textSelection(.enabled) }
            }
        }
        .navigationTitle("设备上的 App")
        .onChange(of: settings.host) { _, _ in deviceApps = nil }
        .onChange(of: settings.pairing) { _, _ in deviceApps = nil }
        .onDisappear { operation?.cancel() }
    }

    private func browse() {
        guard !loading, let pairing = settings.pairing?.data, let token = settings.beginOperation() else { return }
        loading = true; message = nil
        operation = Task {
            defer { settings.endOperation(token); loading = false; operation = nil }
            do { deviceApps = try await InstalledAppBrowser().listApps(host: settings.host, pairingData: pairing) }
            catch { message = ProvisioningRedaction.redact(error.localizedDescription) }
        }
    }
}
