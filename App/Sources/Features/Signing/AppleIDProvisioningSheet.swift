import SwiftUI

struct AppleIDProvisioningSheet: View {
    @ObservedObject var account: AppleIDProvisioningModel
    @ObservedObject var signing: SigningViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?

    private var busy: Bool { operation != nil || account.isBusy || signing.isProvisioning }

    var body: some View {
        NavigationStack {
            Form {
                Section("Anisette 提供方") {
                    Toggle("启用自动申请", isOn: $account.providerEnabled)
                    TextField("HTTPS 提供方地址", text: $account.endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("此提供方接收本地 UUID、ADI 注册握手消息和 ADI blob，并可看到来源 IP。Apple ID、密码、Xcode token、配对记录及签名私钥不会发送给该提供方。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("我同意使用此地址的服务", isOn: $account.providerAccepted)
                        .disabled(!account.providerEnabled)
                    Text("可以替换提供方或关闭自动申请；手动 P12 / PEM 导入仍可使用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(busy)
                if let identity = account.account {
                    Section("Apple ID 与团队") {
                        LabeledContent("账号", value: identity.appleID)
                        Picker("免费 iOS 团队", selection: $account.teamID) {
                            Text("请选择团队").tag("")
                            ForEach(identity.teams) { team in
                                Text("\(team.name)（\(team.id)）").tag(team.id)
                            }
                        }.disabled(busy)
                        Button("退出并清除本机账号资料", role: .destructive) {
                            start { await account.logout() }
                        }.disabled(busy)
                        Text("此操作会清除本应用保存的该账号会话、ADI 和签名材料。iOS 卸载应用不保证清除 Keychain。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("设备与签名") {
                        LabeledContent("IPA", value: signing.ipaName)
                        LabeledContent("配对文件", value: signing.pairingName)
                        TextField("本地 VPN 设备 IP", text: $signing.deviceHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(busy)
                        Button("检测已配对设备") { start { await signing.verifyProvisioningDevice() } }
                            .disabled(busy || signing.pairingName == "未选择")
                        if signing.verifiedDeviceUDID != nil {
                            Label("配对设备已验证", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        }
                        Button("获取材料并签名") {
                            guard let engine = account.engine else { return }
                            let team = account.teamID
                            start {
                                await signing.provisionAndSign(using: engine, account: identity, teamID: team,
                                    providerAccepted: account.providerEnabled && account.providerAccepted,
                                    confirmRevocation: { candidates in await account.confirmRevocation(candidates) })
                            }
                        }
                        .disabled(busy || account.teamID.isEmpty || signing.verifiedDeviceUDID == nil ||
                                  signing.ipaName == "未选择" || !account.providerAccepted || !account.providerEnabled)
                        Text("仅支持无扩展、未加密的单一 arm64 App，并保留原 Bundle ID。免费描述文件通常约 7 天，实际到期日以 Apple 返回并验证的材料为准。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if signing.outputURL != nil {
                            Label("已生成签名 IPA，可返回签名页导出或安装", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                } else {
                    Section("登录 Apple ID") {
                        TextField("Apple ID", text: $account.appleID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                            .disabled(busy)
                        SecureField("密码", text: $account.password).disabled(busy)
                        Button("登录") { start { await account.logIn() } }
                            .disabled(busy || !account.providerEnabled || !account.providerAccepted ||
                                      account.appleID.isEmpty || account.password.isEmpty)
                        Text("密码仅用于本次 Apple 登录，提交、取消或离开页面时清空。会话和签名私钥保存在此设备的专用 Keychain。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if account.awaitingCode {
                    Section("Apple 二次验证") {
                        Text("输入 Apple 提供的六位验证码。验证失败后可重新输入密码登录。")
                        TextField("六位验证码", text: $account.code).keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Button("提交验证码") { account.submitCode() }.disabled(account.code.count != 6)
                    }
                }
                if !account.revocations.isEmpty {
                    Section("确认撤销以下开发证书") {
                        Text("撤销会影响使用这些证书签名的其他 App，也可能影响当前 LocSign。确认后将重新核对远端列表；发生变化会停止。")
                            .foregroundStyle(.red)
                        ForEach(account.revocations) { certificate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(certificate.name).font(.headline)
                                Text("ID：\(certificate.id)")
                                Text("序列号：\(certificate.serialNumber)")
                                Text(certificate.expiry, format: .dateTime.year().month().day().hour().minute())
                            }.font(.footnote).textSelection(.enabled)
                        }
                        Button("保留证书并取消", role: .cancel) { account.resolveRevocation(false) }
                        Button("撤销列表中的全部证书", role: .destructive) { account.resolveRevocation(true) }
                    }
                }
                if busy {
                    Section {
                        HStack { ProgressView(); Text(signing.isProvisioning ? "正在获取材料并签名…" : "正在处理…") }
                        Text("取消会停止本机后续操作，Apple 已完成的注册或撤销无法回滚。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = account.error ?? signing.error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section { NavigationLink("第三方许可") { ThirdPartyLicensesView() } }
            }
            .navigationTitle("Apple ID 自动签名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(busy ? "取消" : "完成") {
                        operation?.cancel()
                        Task { await signing.cancelProvisioning(); await account.cancel(); dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(busy)
            .task { await account.restore() }
            .onChange(of: account.endpoint) { _, _ in Task { await account.changeProvider() } }
            .onChange(of: account.providerEnabled) { _, _ in Task { await account.changeProvider() } }
            .onChange(of: account.providerAccepted) { _, accepted in if accepted { Task { await account.restore() } } }
            .onDisappear {
                operation?.cancel()
                account.password = ""; account.code = ""
                Task { await signing.cancelProvisioning(); await account.cancel() }
            }
        }
    }

    private func start(_ action: @escaping @MainActor () async -> Void) {
        guard operation == nil else { return }
        operation = Task { await action(); operation = nil }
    }
}
