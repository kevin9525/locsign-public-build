import SwiftUI

struct SelfRenewalSection: View {
    @ObservedObject var model: SelfRenewalModel
    @ObservedObject var library: ManagedAppLibrary
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var account: AppleIDProvisioningModel
    let busy: Bool
    let renew: (ManagedApp) -> Void
    @State private var importProfile: InstalledSelfProfile?

    private var managedSelf: ManagedApp? {
        guard let profile = model.profile, library.loadError == nil else { return nil }
        let matches = library.apps.filter {
            $0.identity.signingBundleID == profile.bundleID && $0.identity.teamID == profile.teamID
                && profile.deviceUDIDs.contains($0.identity.deviceUDID)
                && (try? library.sourceURL(for: $0.id)) != nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    var body: some View {
        Section {
            if let profile = model.profile {
                let needsRelaunch = library.selfInstallationNeedsRelaunch(bundleID: profile.bundleID)
                LabeledContent("当前应用标识", value: profile.bundleID)
                    .font(.caption).textSelection(.enabled)
                LabeledContent("描述文件到期") {
                    Text(profile.profileExpiry, format: .dateTime.year().month().day().hour().minute())
                }
                if profile.profileExpiry <= Date() {
                    Text("描述文件已到期，请使用电脑或仍有效的签名工具覆盖更新。").foregroundStyle(.red)
                } else if profile.profileExpiry.timeIntervalSinceNow <= 48 * 3600 {
                    Text("将在 48 小时内到期，请尽快手动续签 LocSign。").foregroundStyle(.orange)
                }
                Toggle("提醒我续签 LocSign", isOn: Binding(get: { model.remindersEnabled }, set: { enabled in
                    Task { await model.setRemindersEnabled(enabled) }
                }))
                if let app = managedSelf {
                    Button("立即续签 LocSign") { renew(app) }.disabled(busy || needsRelaunch)
                } else {
                    Text("尚未找到可用的自身 IPA 记录。首次选择 LocSign IPA 更新一次，之后即可直接续签。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(managedSelf == nil ? "选择 LocSign IPA 并续签" : "更换 LocSign IPA 并更新") { importProfile = profile }
                    .disabled(busy || needsRelaunch)
                if needsRelaunch {
                    Text(SelfInstallationAwaitingVerification.message).font(.footnote).foregroundStyle(.orange)
                }
            } else {
                Text(model.profileError ?? "正在读取当前安装的描述文件…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.notificationError { Text(error).font(.footnote).foregroundStyle(.orange) }
            DisclosureGroup("如果 LocSign 已经过期") {
                Text("过期后通常无法打开，也无法在自身内部续签。保留手机上的 LocSign，在电脑使用原 Apple ID 和原应用标识重新签名、覆盖安装；不要先卸载，以免丢失本地资料。仍有效且已配置好材料的其他签名工具也可用于覆盖更新。")
                    .font(.footnote)
            }
        } header: { Text("LocSign 自身") } footer: {
            Text("以当前安装的描述文件为准，不按安装日推算 7 天；证书被撤销可能提前失效。开启通知后提前 48 小时和 24 小时提醒，已错过的时间不补发。提醒不自动续签，通知显示受系统设置影响。")
        }
        .sheet(item: $importProfile, onDismiss: { Task { await model.refresh() } }) { profile in
            SelfRenewalSetupView(profile: profile, settings: settings, library: library, account: account)
        }
    }
}

private struct SelfRenewalSetupView: View {
    let settings: InstallationSettings
    let account: AppleIDProvisioningModel
    @StateObject private var signing: SigningViewModel

    init(profile: InstalledSelfProfile, settings: InstallationSettings, library: ManagedAppLibrary, account: AppleIDProvisioningModel) {
        self.settings = settings; self.account = account
        _signing = StateObject(wrappedValue: SigningViewModel(settings: settings, library: library, selfRenewalProfile: profile))
    }
    var body: some View { SigningView(settings: settings, model: signing, account: account) }
}
