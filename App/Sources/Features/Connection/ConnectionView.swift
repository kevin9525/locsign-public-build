import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ConnectionView: View {
    @StateObject private var model: ConnectionViewModel
    @State private var task: Task<Void, Never>?
    @State private var importing = false
    @State private var cancelling = false
    @Environment(\.openURL) private var openURL

    init(settings: InstallationSettings) {
        _model = StateObject(wrappedValue: ConnectionViewModel(settings: settings))
    }

    private var busy: Bool { task != nil || model.deviceBusy }

    var body: some View {
        Form {
            Section {
                Label("连接并验证这台手机", systemImage: "cable.connector").font(.headline)
                Text("一次检查设备响应、配对认证和安装服务。签名安装仍会自动验证设备，平时无需先做自检。")
                    .foregroundStyle(.secondary)
                Button(action: { start(full: true) }) {
                    Label(model.checkedAt == nil ? "一键连接自检" : "重新自检", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(task != nil || !model.canRunSelfCheck)
                if model.deviceBusy && task == nil {
                    Text("请等待当前设备操作完成后再检查。").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("自检只验证连接，不会安装 App 或修改定位。安装服务连通也不代表定位开发者服务已就绪。")
            }

            Section {
                TextField("设备 IP / 本地 VPN 地址", text: $model.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy)
                Button { importing = true } label: {
                    HStack {
                        Text("导入配对文件")
                        Spacer()
                        Text(model.pairingName).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "folder")
                    }
                }
                .disabled(busy)
            } header: { Text("设备设置") } footer: {
                Text("LocalDevVPN 通常为 10.7.0.1。配对文件与签名、定位共用；尚无配对时也可先检查设备响应。")
            }

            if !model.steps.isEmpty {
                Section {
                    ForEach(ConnectionCheckStep.allCases) { step in stepRow(step) }
                    if let date = model.checkedAt {
                        LabeledContent("本次检查时间") {
                            Text(date, format: .dateTime.month().day().hour().minute().second())
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("检查项目") } footer: {
                    Text("结果仅代表本次检查。更改地址或配对后会清除结果；网络变化后请重新自检。设备响应最多等待 8 秒，后续各网络步骤分别有超时限制。")
                }
            }

            if task != nil {
                Section {
                    HStack {
                        ProgressView()
                        Text(cancelling ? "正在取消，等待当前网络步骤结束…" : "正在检查设备…")
                    }
                    Button("取消", role: .cancel, action: cancel).disabled(cancelling)
                }
            }

            if !model.message.isEmpty {
                Section("检查结果") {
                    Text(model.message).textSelection(.enabled)
                    if let result = model.pairedResult {
                        Text("设备尾号：\(String(result.deviceUDID.suffix(6)))").foregroundStyle(.secondary)
                        Text("服务连接已验证；实际安装需要有效签名的 IPA，实际定位需在地图中核对。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if let failed = model.failedStep {
                    Text(failed.guidance).font(.footnote).foregroundStyle(.secondary)
                    if failed == .pairingFile || failed == .authentication {
                        Button("重新导入配对文件") { importing = true }.disabled(busy)
                    }
                } else {
                    Text("保持手机解锁、LocalDevVPN 开启；需要调整本地网络权限时，可打开 LocSign 的系统设置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("打开 LocSign 系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .disabled(busy)
                NavigationLink("诊断日志") { DiagnosticLogsView() }.disabled(busy)
                DisclosureGroup("高级检测") {
                    Button("仅检测设备响应") { start(full: false) }.disabled(busy)
                }
            } header: { Text("处理与排查") }
        }
        .navigationTitle("连接自检")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do { try model.importPairing(result.get()) }
            catch {
                if (error as NSError).code != NSUserCancelledError { model.reportImportError(error) }
            }
        }
        .onDisappear { cancel() }
    }

    private func stepRow(_ step: ConnectionCheckStep) -> some View {
        let state = model.state(for: step)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: state.icon)
                .foregroundStyle(state == .passed ? Color.green : state == .failed ? .orange : .secondary)
                .accessibilityHidden(true)
            Text(step.title)
            Spacer(minLength: 8)
            Text(state.title).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func start(full: Bool) {
        guard task == nil, model.canRunSelfCheck else { return }
        cancelling = false
        task = Task { @MainActor in
            defer { task = nil; cancelling = false }
            if full { await model.checkPairing() }
            else { await model.checkReachability() }
        }
    }

    private func cancel() {
        guard task != nil else { return }
        cancelling = true
        task?.cancel()
    }
}
