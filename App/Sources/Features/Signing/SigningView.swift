import SwiftUI
import UniformTypeIdentifiers

struct SigningView: View {
    @StateObject private var model = SigningViewModel()
    @State private var importing = false
    @State private var input: SigningInput = .ipa

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("导入、签名、导出", systemImage: "signature")
                        .font(.headline)
                    Text("使用已有证书为 IPA 签名，签名完成后保存或分享文件。")
                        .foregroundStyle(.secondary)
                }
                Section("应用与签名材料") {
                    importButton("IPA 文件", value: model.ipaName, kind: .ipa)
                    importButton("签名证书 / 私钥", value: model.identityName, kind: .identity)
                    importButton("描述文件", value: model.profile?.name ?? "未选择", kind: .profile)
                    importButton("设备配对文件", value: model.pairingName, kind: .pairing)
                    if model.needsPassword {
                        SecureField("P12 密码（无密码则留空）", text: $model.password)
                            .textInputAutocapitalization(.never)
                    }
                }
                .disabled(model.isSigning || model.isImporting || model.isInstalling)
                if model.isImporting {
                    Section { HStack { ProgressView(); Text("正在导入文件…") } }
                }
                if let profile = model.profile {
                    Section("描述文件信息") {
                        LabeledContent("应用标识", value: profile.bundleID)
                        LabeledContent("开发团队", value: profile.teamID)
                        LabeledContent("有效期") { Text(profile.expiry, style: .date) }
                        if profile.expiry <= Date() {
                            Label("描述文件已过期", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await model.sign() }
                    } label: {
                        HStack {
                            if model.isSigning { ProgressView() }
                            Text(model.isSigning ? "正在签名…" : "签名 IPA")
                        }
                    }
                    .disabled(!model.canSign)
                    if let output = model.outputURL {
                        Label("已生成签名文件", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        ShareLink(item: output) { Label("保存或分享 IPA", systemImage: "square.and.arrow.up") }
                        Button("清除本次产物", role: .destructive) { model.discardOutput() }
                            .disabled(model.isInstalling)
                        Text("是否可安装还取决于描述文件中的设备、权限与有效期。")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("手机本地 VPN 提供的地址", text: $model.deviceHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(model.isInstalling)
                        Button {
                            Task { await model.installSignedIPA() }
                        } label: {
                            HStack {
                                if model.isInstalling { ProgressView() }
                                Text(model.isInstalling ? "正在上传并安装…" : "安装到已配对手机")
                            }
                        }
                        .disabled(model.isInstalling || model.isImporting || model.isSigning || model.pairingName == "未选择")
                        if model.isInstalling { ProgressView(value: model.installProgress) }
                        if model.installSucceeded {
                            Label("设备安装服务已完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                } footer: {
                    Text("导入电脑生成的配对 plist，配置手机本地 VPN 地址后可尝试自安装。首次配对仍需电脑；免费 Apple ID 签名流程尚未接入。")
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle("签名")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    let kind = input
                    Task { await model.importFile(url, as: kind) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { model.error = error.localizedDescription }
                }
            }
        }
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
