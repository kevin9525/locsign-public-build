import SwiftUI
import UniformTypeIdentifiers

struct ConnectionView: View {
    @StateObject private var model: ConnectionViewModel
    init(settings: InstallationSettings) {
        _model = StateObject(wrappedValue: ConnectionViewModel(settings: settings))
    }
    @State private var task: Task<Void, Never>?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("连接并验证这台手机", systemImage: "cable.connector")
                        .font(.headline)
                    Text("这里用于排查连接问题。一键安装会自动验证设备，无需每次先来检测。配对文件与安装页共用。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("设备 IP / 本地 VPN 地址", text: $model.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(task != nil || model.deviceBusy)
                    Button("检测连接") { start(pairing: false) }
                        .disabled(task != nil || model.deviceBusy || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("设备地址")
                } footer: {
                    Text("LocalDevVPN 默认地址为 10.7.0.1。连接检测最多等待 8 秒。")
                }
                Section {
                    Button { importing = true } label: {
                        HStack {
                            Text("设备配对文件")
                            Spacer()
                            Text(model.pairingName).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "folder")
                        }
                    }
                    .disabled(task != nil || model.deviceBusy)
                    Button("验证配对与安装服务") { start(pairing: true) }
                        .disabled(task != nil || !model.canCheckPairing)
                } header: {
                    Text("配对验证")
                } footer: {
                    Text("此检查无需签名证书，会验证设备身份和服务连接。每个网络步骤有超时限制；检查期间保持手机解锁、VPN 开启。")
                }
                if task != nil {
                    Section {
                        HStack { ProgressView(); Text("正在检查设备…") }
                        Button("取消", role: .cancel) { task?.cancel() }
                    }
                }
                if !model.message.isEmpty {
                    Section("检查结果") {
                        Text(model.message).textSelection(.enabled)
                        if let result = model.pairedResult {
                            Label("配对身份认证通过", systemImage: "checkmark.shield")
                            Label("文件传输服务连接正常", systemImage: "checkmark.circle")
                            Label("安装服务连接正常", systemImage: "checkmark.circle")
                            Text("设备尾号：\(String(result.deviceUDID.suffix(6)))")
                                .foregroundStyle(.secondary)
                            Text("服务连接正常后，还需使用有效签名的 IPA 验证实际安装。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if model.reachable {
                            Text("已确认服务可达，尚未验证配对身份。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("设备连接")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do { try model.importPairing(result.get()) }
                catch {
                    if (error as NSError).code != NSUserCancelledError { model.reportImportError(error) }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func start(pairing: Bool) {
        guard task == nil else { return }
        task = Task { @MainActor in
            defer { task = nil }
            if pairing { await model.checkPairing() }
            else { await model.checkReachability() }
        }
    }
}
