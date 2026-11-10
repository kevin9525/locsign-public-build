import Foundation
import Combine

@MainActor
final class AppRenewalCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var stage = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published var enabled: Bool {
        didSet { settings.defaults.set(enabled, forKey: "renewal.enabled"); if !enabled { cancel() } }
    }
    var notifyFailure: (@MainActor (String) async -> Void)?
    private let settings: InstallationSettings
    private let library: ManagedAppLibrary
    private let account: AppleIDProvisioningModel
    private let installer: any IPAInstalling
    private let probe: any PairedDeviceProbing
    private let inspect: @Sendable (URL) throws -> ProvisioningApp
    private let sign: @MainActor (URL, ProvisioningMaterial) async throws -> URL
    private let now: () -> Date
    private let runningBundleID: String?
    private var operation: Task<Bool, Never>?

    init(settings: InstallationSettings, library: ManagedAppLibrary, account: AppleIDProvisioningModel,
         installer: any IPAInstalling = InstallCoordinator(), probe: any PairedDeviceProbing = ProvisioningDeviceProbe(),
         runningBundleID: String? = Bundle.main.bundleIdentifier, now: @escaping () -> Date = Date.init,
         inspect: @escaping @Sendable (URL) throws -> ProvisioningApp = { try ProvisioningIPAPreflight().inspect($0) },
         sign: @escaping @MainActor (URL, ProvisioningMaterial) async throws -> URL = SigningViewModel.signProvisionedMaterial) {
        self.settings = settings; self.library = library; self.account = account
        self.installer = installer; self.probe = probe; self.runningBundleID = runningBundleID
        self.now = now; self.inspect = inspect; self.sign = sign
        enabled = settings.defaults.object(forKey: "renewal.enabled") as? Bool ?? true
    }

    func runDue() async -> Bool {
        guard enabled else { return true }
        let date = now()
        let ids = library.apps.filter { AppRenewalPolicy.due($0, now: date, runningBundleID: runningBundleID) }
            .sorted { ($0.effectiveExpiry ?? .distantFuture) < ($1.effectiveExpiry ?? .distantFuture) }.map(\.id)
        return await run(ids: ids, automatic: true)
    }
    func renew(id: UUID) async -> Bool { await run(ids: [id], automatic: false) }
    func cancel() { operation?.cancel() }

    private func run(ids: [UUID], automatic: Bool) async -> Bool {
        guard !isRunning, settings.operationID == nil, !account.isBusy else { return false }
        guard !ids.isEmpty else { return true }
        guard let token = settings.beginOperation() else { return false }
        isRunning = true; error = nil; progress = 0
        let task = Task { @MainActor in
            var succeeded = true
            for id in ids {
                if Task.isCancelled { return false }
                guard let app = library.apps.first(where: { $0.id == id }) else { continue }
                if automatic && (!enabled || !AppRenewalPolicy.due(app, now: now(), runningBundleID: runningBundleID)) { continue }
                do {
                    try library.recordAttempt(id: id, now: now())
                    try await renewApp(app)
                    stage = app.identity.signingBundleID == runningBundleID ? "等待重新打开 LocSign 核对自身续签" : "\(app.name) 续签完成"
                } catch {
                    succeeded = false
                    let message = error is CancellationError ? "续签已暂停，下次打开 App 时重试" : ProvisioningRedaction.redact(error.localizedDescription)
                    self.error = message
                    try? library.fail(id: id, message: message, preservePending: app.identity.signingBundleID == runningBundleID)
                    stage = "\(app.name) 续签未完成"
                    if automatic && !(error is CancellationError) { await notifyFailure?(app.name) }
                    if Task.isCancelled { return false }
                }
            }
            return succeeded
        }
        operation = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        operation = nil; isRunning = false; settings.endOperation(token)
        return result
    }

    private func renewApp(_ app: ManagedApp) async throws {
        try Task.checkCancellation()
        stage = "\(app.name)：检查账号与原 IPA…"; progress = 0
        let source = try library.sourceURL(for: app.id)
        await account.restore()
        try Task.checkCancellation()
        guard let identity = account.account, let engine = account.engine,
              ProvisioningKeychain.normalize(identity.appleID) == app.identity.appleID,
              identity.teams.contains(where: { $0.id == app.identity.teamID }) else {
            throw LocSignError.install("请在安装页登录此应用原来使用的 Apple ID 和团队")
        }
        let inspect = inspect
        let inspecting = Task.detached(priority: .utility) { try inspect(source) }
        let original = try await withTaskCancellationHandler { try await inspecting.value } onCancel: { inspecting.cancel() }
        try Task.checkCancellation()
        guard original.bundleID == app.identity.originalBundleID else { throw LocSignError.install("保存的原 IPA 与应用记录不符，请重新导入") }
        guard let pairing = settings.pairing?.data else { throw LocSignError.install("请先在安装页导入设备配对文件") }
        stage = "\(app.name)：连接设备…"
        let device = try await probe.deviceUDID(host: settings.host, pairingData: pairing)
        try Task.checkCancellation()
        guard device == app.identity.deviceUDID else { throw LocSignError.install("连接的设备与此应用记录不一致，已停止续签") }
        let minimum = AppRenewalPolicy.minimumExpiry(app, now: now())
        let request = ProvisioningRequest(accountID: identity.id, teamID: app.identity.teamID, ipaURL: source,
            deviceUDID: device, signingBundleID: app.identity.signingBundleID, minimumProfileExpiry: minimum)
        stage = "\(app.name)：获取新的有效期…"
        let material: ProvisioningMaterial
        if let cached = try await engine.cachedMaterial(request: request) { material = cached }
        else {
            guard account.providerAccepted, account.providerEnabled, !account.requiresLogin else {
                throw LocSignError.install("续签需要重新登录 Apple ID 并确认签名服务，请到安装页处理")
            }
            // Background and unattended foreground work must never present or
            // automatically approve certificate revocation.
            material = try await engine.provision(request: request, confirmRevocation: { _ in false })
        }
        try Task.checkCancellation()
        guard material.profileExpiry > minimum, material.certificateExpiry > now().addingTimeInterval(AppRenewalPolicy.renewalWindow),
              material.signingBundleID == app.identity.signingBundleID else {
            throw LocSignError.install("没有获得有效期更长的匹配材料，请稍后重试；若证书即将到期，请在安装页处理")
        }
        stage = "\(app.name)：签名…"
        let output = try await sign(source, material)
        defer { try? FileManager.default.removeItem(at: output) }
        try Task.checkCancellation()
        let id = try await library.prepare(source: source, name: app.name, identity: app.identity, material: material)
        try Task.checkCancellation()
        stage = "\(app.name)：上传并安装…"
        try await installer.install(ipaURL: output, host: settings.host, pairingData: pairing) { [weak self] value in
            await MainActor.run { self?.progress = value }
        }
        try Task.checkCancellation()
        do {
            if app.identity.signingBundleID != runningBundleID { try library.confirmInstallation(id: id, now: now()) }
        }
        catch { throw LocSignError.install("设备安装已完成，但记录未保存。请重新打开应用后检查：" + error.localizedDescription) }
        progress = 1
    }
}
