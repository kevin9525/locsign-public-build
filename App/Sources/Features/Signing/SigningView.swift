import SwiftUI
import UniformTypeIdentifiers

struct SigningView: View {
    @ObservedObject private var settings: InstallationSettings
    @StateObject private var model: SigningViewModel
    @StateObject private var account: AppleIDProvisioningModel
    @State private var showingAppleID = false
    @State private var importing = false
    @State private var input: SigningInput = .ipa
    @State private var operation: Task<Void, Never>?
    @State private var continueAfterSetup = false
    @State private var setupForInstallation = false

    init(settings: InstallationSettings, model: SigningViewModel, account: AppleIDProvisioningModel) {
        self.settings = settings
        _model = StateObject(wrappedValue: model)
        _account = StateObject(wrappedValue: account)
    }

    private var busy: Bool { model.busy || account.isBusy || operation != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    importButton("选择 IPA", value: model.ipaName, kind: .ipa)
                        .disabled(busy)
                    Button(action: startInstallation) {
                        Label("一键安装", systemImage: "arrow.down.app.fill").font(.headline)
                    }.disabled(busy || model.ipaName == "未选择")
                } footer: {
                    Text("自动检查设备、复用或获取材料、签名并安装。请保持手机解锁、LocalDevVPN 开启。")
                }
                if model.isImporting || model.isPreparingIdentifier {
                    Section { HStack { ProgressView(); Text(model.isImporting ? "正在导入 IPA…" : "正在读取应用设置…") } }
                }
                if model.isSigning {
                    Section { HStack { ProgressView(); Text("正在签名 IPA…") } }
                }
                if operation != nil {
                    Section("安装进度") {
                        HStack { ProgressView(); Text(model.stage.isEmpty ? "正在准备…" : model.stage) }
                        if model.isInstalling { ProgressView(value: model.installProgress) }
                        Button("取消", role: .cancel, action: cancelInstallation)
                        Text("取消会停止后续操作；设备已开始的安装可能仍会完成。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Apple ID 与签名设置") {
                        setupForInstallation = false
                        showingAppleID = true
                    }.disabled(busy)
                    LabeledContent("账号", value: account.account?.appleID ?? "首次使用请登录")
                    if !account.teamID.isEmpty { LabeledContent("团队", value: account.teamID) }
                    DisclosureGroup(settings.pairing == nil ? "首次设置：导入配对文件" : "已保存设备设置") {
                        importButton("设备配对文件", value: model.pairingName, kind: .pairing)
                        TextField("本地 VPN 设备 IP", text: $model.deviceHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if settings.pairing != nil {
                            Button("清除保存的配对文件", role: .destructive) {
                                do { try settings.clearPairing() }
                                catch { model.error = error.localizedDescription }
                            }
                        }
                        Text("只需导入一次，连接页与本页共用。默认设备地址为 10.7.0.1，无需先手动检测。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(busy)
                }
                if let output = model.outputURL {
                    Section("签名文件") {
                        if model.installSucceeded {
                            Label("安装完成，可回到主屏幕打开应用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("已生成签名 IPA", systemImage: "signature")
                        }
                        if let expiry = model.profileExpiry {
                            LabeledContent("有效期") { Text(expiry, format: .dateTime.year().month().day().hour().minute()) }
                        }
                        ShareLink(item: output) { Label("保存或分享 IPA", systemImage: "square.and.arrow.up") }
                            .disabled(busy)
                        if !model.installSucceeded {
                            Button("安装此签名文件") { startSignedInstallation() }.disabled(busy || settings.pairing == nil)
                        }
                        Button("清除本次产物", role: .destructive) { model.discardOutput() }.disabled(busy)
                    }
                }
                if let error = model.error ?? account.error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    DisclosureGroup("高级选项：手动签名") {
                        importButton("签名证书 / 私钥", value: model.identityName, kind: .identity)
                        importButton("描述文件", value: model.profile?.name ?? "未选择", kind: .profile)
                        if model.needsPassword {
                            SecureField("P12 密码（无密码则留空）", text: $model.password)
                                .textInputAutocapitalization(.never)
                        }
                        if let profile = model.profile {
                            LabeledContent("应用标识", value: profile.bundleID)
                            LabeledContent("有效期") { Text(profile.expiry, style: .date) }
                        }
                        Button("使用导入材料签名") { Task { await model.sign() } }.disabled(!model.canSign)
                    }.disabled(busy)
                }
            }
            .navigationTitle("安装")
            .onChange(of: account.teamID) { _, team in
                Task { await model.restoreSigningIdentifier(teamID: team) }
            }
            .onChange(of: account.revocations.isEmpty) { _, empty in
                if model.isOneClickInstalling { showingAppleID = !empty }
            }
            .sheet(isPresented: $showingAppleID, onDismiss: {
                if continueAfterSetup { continueAfterSetup = false; startInstallation() }
            }) {
                AppleIDProvisioningSheet(account: account, signing: model,
                    continueInstallation: setupForInstallation ? {
                        continueAfterSetup = true
                        showingAppleID = false
                    } : nil, cancelInstallation: cancelInstallation)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    let kind = input
                    Task {
                        await model.importFile(url, as: kind)
                        if kind == .ipa { await model.restoreSigningIdentifier(teamID: account.teamID) }
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { model.error = error.localizedDescription }
                }
            }
        }
    }

    private func startInstallation() {
        guard !busy else { return }
        guard settings.pairing != nil else {
            model.error = "首次使用请先导入这台手机的配对文件，之后会自动记住。"
            input = .pairing
            importing = true
            return
        }
        guard let identity = account.account, let engine = account.engine, !account.teamID.isEmpty else {
            setupForInstallation = true
            showingAppleID = true
            return
        }
        operation = Task { @MainActor in
            await model.installIPA(using: engine, account: identity, teamID: account.teamID,
                canProvision: account.providerEnabled && account.providerAccepted && !account.requiresLogin,
                confirmRevocation: { candidates in await account.confirmRevocation(candidates) })
            operation = nil
            if model.needsAccountSetup {
                account.requireLogin()
                setupForInstallation = true
                showingAppleID = true
            }
        }
    }

    private func startSignedInstallation() {
        guard !busy else { return }
        operation = Task { await model.installSignedIPA(); operation = nil }
    }

    private func cancelInstallation() {
        operation?.cancel()
        Task { await model.cancelProvisioning(); await account.cancel() }
    }

    private func importButton(_ title: String, value: String, kind: SigningInput) -> some View {
        Button { input = kind; importing = true } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "folder")
            }
        }
    }
}
