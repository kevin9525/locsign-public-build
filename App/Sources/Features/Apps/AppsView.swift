import SwiftUI

struct AppsView: View {
    @ObservedObject var library: ManagedAppLibrary
    @ObservedObject var renewal: AppRenewalCoordinator
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var account: AppleIDProvisioningModel
    let background: RenewalBackgroundService
    @State private var deviceApps: InstalledAppList?
    @State private var loading = false
    @State private var message: String?
    @State private var removal: ManagedApp?
    @State private var selfRenewal: ManagedApp?
    @State private var operation: Task<Void, Never>?

    private var busy: Bool { settings.operationID != nil || account.isBusy || renewal.isRunning || loading }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("自动续签", isOn: $renewal.enabled)
                        .onChange(of: renewal.enabled) { _, _ in background.schedule() }
                    Button("开启续签失败通知") {
                        Task {
                            let allowed = await background.requestNotifications()
                            message = allowed ? "已允许失败通知" : "通知未开启，可到 iOS 设置中允许 LocSign 通知"
                        }
                    }
                    Button("检查并续签即将到期的 App") {
                        operation = Task { _ = await renewal.runDue(); background.schedule(); operation = nil }
                    }.disabled(busy || !renewal.enabled)
                } footer: {
                    Text("到期前 48 小时尝试续签。后台由 iOS 安排，打开 LocSign 时补做；失败后至少间隔 6 小时重试。请保持 LocalDevVPN 开启。")
                }
                if renewal.isRunning {
                    Section("续签进度") {
                        Text(renewal.stage)
                        ProgressView(value: renewal.progress)
                        Button("暂停续签", role: .cancel) { renewal.cancel() }
                    }
                }
                Section("可管理的 App") {
                    if library.apps.isEmpty {
                        Text("通过新版 LocSign 安装一次 IPA，即可保存原文件并加入续签列表。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.apps) { app in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(app.name, systemImage: "app.fill").font(.headline)
                            Text(app.identity.signingBundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let expiry = app.effectiveExpiry {
                                HStack {
                                    Text(expiry <= Date() ? "已到期" : "有效期至")
                                    Text(expiry, format: .dateTime.year().month().day().hour().minute())
                                }.font(.subheadline).foregroundStyle(expiry <= Date() ? .red : .secondary)
                            } else { Text("安装结果待确认").foregroundStyle(.orange) }
                            if app.pending != nil { Text("上次安装尚未确认，原到期时间保持不变").font(.caption).foregroundStyle(.orange) }
                            if let lastError = app.lastError { Text(lastError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            if app.identity.signingBundleID == Bundle.main.bundleIdentifier {
                                Text("LocSign 自身请手动续签，安装时应用会退出。").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Toggle("自动续签此 App", isOn: Binding(get: { app.autoRenew }, set: { value in
                                    do { try library.setAutoRenew(id: app.id, enabled: value); background.schedule() }
                                    catch { message = error.localizedDescription }
                                })).disabled(busy)
                            }
                            HStack {
                                Button("立即续签") {
                                    if app.identity.signingBundleID == Bundle.main.bundleIdentifier { selfRenewal = app }
                                    else { renew(app) }
                                }.buttonStyle(.borderedProminent)
                                Button("清除记录", role: .destructive) { removal = app }.buttonStyle(.bordered)
                            }.disabled(busy)
                        }.padding(.vertical, 5)
                    }
                }
                Section {
                    Button(loading ? "正在读取设备 App…" : "读取已安装 App 列表", action: browse).disabled(busy || settings.pairing == nil)
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
                } header: { Text("设备上的 App") } footer: {
                    Text("这里只读取用户安装的 App；系统 App 不在列表中。清除本地记录不会卸载手机上的 App，但会删除 LocSign 保存的原 IPA。")
                }
                if let error = library.loadError ?? message ?? renewal.error {
                    Section { Text(error).textSelection(.enabled) }
                }
            }
            .navigationTitle("App 管理")
            .onChange(of: settings.host) { _, _ in deviceApps = nil }
            .onChange(of: settings.pairing) { _, _ in deviceApps = nil }
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
    }

    private func renew(_ app: ManagedApp) {
        guard !busy else { return }
        operation = Task { _ = await renewal.renew(id: app.id); background.schedule(); operation = nil }
    }
    private func browse() {
        guard !busy, let pairing = settings.pairing?.data, let token = settings.beginOperation() else { return }
        loading = true; message = nil
        operation = Task {
            defer { settings.endOperation(token); loading = false; operation = nil }
            do { deviceApps = try await InstalledAppBrowser().listApps(host: settings.host, pairingData: pairing) }
            catch { message = ProvisioningRedaction.redact(error.localizedDescription) }
        }
    }
}
