import SwiftUI
import UniformTypeIdentifiers

/// Main signing page: readiness checklist, IPA picker, one-tap sign & install
/// with step progress, and (on the main tab) the list of signed apps.
struct SigningView: View {
    @ObservedObject private var settings: InstallationSettings
    @StateObject private var model: SigningViewModel
    @StateObject private var account: AppleIDProvisioningModel
    private let appsSection: AnyView?
    @State private var showingAppleID = false
    @State private var importing = false
    @State private var input: SigningInput = .ipa
    @State private var operation: Task<Void, Never>?
    @State private var continueAfterSetup = false
    @State private var setupForInstallation = false
    @State private var confirmingSelfInstall = false
    @Environment(\.dismiss) private var dismiss

    init(settings: InstallationSettings, model: SigningViewModel, account: AppleIDProvisioningModel,
         appsSection: AnyView? = nil) {
        self.settings = settings
        self.appsSection = appsSection
        _model = StateObject(wrappedValue: model)
        _account = StateObject(wrappedValue: account)
    }

    private var busy: Bool { model.busy || account.isBusy || operation != nil }
    private var isSelfRenewal: Bool { model.selfRenewalProfile != nil }
    private var hasIPA: Bool { model.ipaName != "未选择" }
    private var accountReady: Bool { account.account != nil && !account.requiresLogin && !account.teamID.isEmpty }

    private static let steps = ["检查 IPA", "连接设备", "准备证书", "签名", "安装"]
    private var currentStep: Int {
        let stage = model.stage
        if stage.contains("检查 IPA") { return 0 }
        if stage.contains("连接") || stage.contains("验证配对") { return 1 }
        if stage.contains("签名材料") { return 2 }
        if stage.contains("签名 IPA") { return 3 }
        if stage.contains("上传") || stage.contains("安装") || stage.contains("保存可续签") { return 4 }
        return 0
    }

    var body: some View {
        NavigationStack {
            Form {
                readinessSection
                installSection
                if model.isImporting || model.isPreparingIdentifier {
                    Section { HStack { ProgressView(); Text(model.isImporting ? "正在导入 IPA…" : "正在读取应用设置…") } }
                }
                if model.isSigning && operation == nil {
                    Section { HStack { ProgressView(); Text("正在签名 IPA…") } }
                }
                if operation != nil { progressSection }
                if model.awaitingSelfVerification {
                    Section("安装结果待核验") {
                        Text(SelfInstallationAwaitingVerification.message).foregroundStyle(.orange)
                    }
                }
                if let output = model.outputURL { resultSection(output) }
                if let error = model.error ?? account.error {
                    Section {
                        Label { Text(error).textSelection(.enabled) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }.foregroundStyle(.red)
                    }
                }
                if let appsSection, !isSelfRenewal { appsSection }
                if !isSelfRenewal { manualSigningSection }
            }
            .navigationTitle(isSelfRenewal ? "LocSign 自身续签" : "签名")
            .toolbar {
                if isSelfRenewal {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(busy) }
                }
            }
            .interactiveDismissDisabled(busy)
            .alert("续签并更新当前 LocSign？", isPresented: $confirmingSelfInstall) {
                Button("取消", role: .cancel) {}
                Button("继续", action: startInstallation)
            } message: { Text("将保存原 IPA，并使用当前应用标识覆盖安装。安装会使 LocSign 退出，请重新打开后检查到期时间。") }
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

    // MARK: Sections

    private var readinessSection: some View {
        Section {
            readinessRow("设备配对文件", done: settings.pairing != nil,
                         detail: settings.pairing?.name ?? "首次使用需导入一次，之后自动记住") {
                input = .pairing
                importing = true
            }
            readinessRow("Apple ID", done: accountReady, detail: accountDetail) {
                setupForInstallation = false
                showingAppleID = true
            }
            LabeledContent {
                TextField("10.7.0.1", text: $model.deviceHost)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.verifiedDeviceUDID == nil ? "iphone" : "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(model.verifiedDeviceUDID == nil ? Color.secondary : Color.green)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设备地址")
                        Text(model.verifiedDeviceUDID == nil ? "安装时自动验证" : "已验证本机")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("准备") } footer: {
            Text("保持手机解锁、LocalDevVPN 开启。设备地址一般保持默认 10.7.0.1。")
        }
        .disabled(busy)
    }

    private var accountDetail: String {
        if accountReady { return account.account?.appleID ?? "" }
        if account.account == nil { return "登录后自动申请证书和描述文件" }
        return account.requiresLogin ? "登录已过期，请重新登录" : "请选择团队"
    }

    private func readinessRow(_ title: String, done: Bool, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(done ? Color.green : Color.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(done ? "更改" : "设置").font(.subheadline)
            }
        }
    }

    private var installSection: some View {
        Section {
            Button { input = .ipa; importing = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.tint).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasIPA ? model.ipaName : (isSelfRenewal ? "选择 LocSign IPA" : "选择 IPA 文件"))
                            .font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(hasIPA ? "点按更换" : "从“文件”中选择要安装的 App")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .disabled(busy)
            Button {
                if isSelfRenewal { confirmingSelfInstall = true } else { startInstallation() }
            } label: {
                Label(isSelfRenewal ? "续签并更新 LocSign" : "签名并安装", systemImage: "arrow.down.app.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || !hasIPA || model.awaitingSelfVerification)
        } header: { Text(isSelfRenewal ? "更新 LocSign" : "安装 App") } footer: {
            if let profile = model.selfRenewalProfile {
                Text("使用当前标识 \(profile.bundleID) 和原团队更新自身。安装期间 App 会退出，重新打开后核对新的到期时间。")
            } else {
                Text("自动检查设备、复用或申请证书、签名并安装。")
            }
        }
    }

    private var progressSection: some View {
        Section("进度") {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 12) {
                    Group {
                        if index < currentStep {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if index == currentStep {
                            ProgressView()
                        } else {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 22)
                    Text(title).foregroundStyle(index > currentStep ? Color.secondary : Color.primary)
                }
            }
            if model.isInstalling { ProgressView(value: model.installProgress) }
            if !model.stage.isEmpty { Text(model.stage).font(.footnote).foregroundStyle(.secondary) }
            Button("取消", role: .cancel, action: cancelInstallation)
            Text("取消会停止后续操作；设备已开始的安装可能仍会完成。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ output: URL) -> some View {
        Section {
            if model.installSucceeded {
                Label(isSelfRenewal ? "请重新打开 LocSign 核对续签结果" : "安装完成，可回到主屏幕打开",
                      systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            } else {
                Label("已生成签名 IPA", systemImage: "signature")
            }
            if let expiry = model.profileExpiry {
                LabeledContent("有效期至") { Text(expiry, format: .dateTime.year().month().day().hour().minute()) }
            }
            ShareLink(item: output) { Label("保存或分享 IPA", systemImage: "square.and.arrow.up") }
                .disabled(busy)
            if !model.installSucceeded && !model.awaitingSelfVerification {
                Button("安装此签名文件") { startSignedInstallation() }.disabled(busy || settings.pairing == nil)
            }
            Button("清除本次产物", role: .destructive) { model.discardOutput() }.disabled(busy)
        } header: { Text("结果") } footer: {
            if model.installSucceeded && !isSelfRenewal {
                Text("免费账号签名约 7 天有效，到期前可在下方“已签名的 App”中续签。")
            }
        }
    }

    private var manualSigningSection: some View {
        Section {
            DisclosureGroup("高级：使用自己的证书和描述文件") {
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
            }
            .disabled(busy)
        }
    }

    // MARK: Actions

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
