import Foundation
import Combine

enum SigningInput: Equatable { case ipa, identity, profile, pairing }

@MainActor
final class SigningViewModel: ObservableObject {
    @Published private(set) var ipaName = "未选择"
    @Published private(set) var identityName = "未选择"
    @Published private(set) var profile: ProvisioningProfileData?
    @Published private(set) var needsPassword = false
    @Published var password = ""
    @Published private(set) var isSigning = false
    @Published private(set) var isImporting = false
    @Published private(set) var outputURL: URL?
    @Published private(set) var pairingName = "未选择"
    @Published private(set) var isInstalling = false
    @Published private(set) var isProvisioning = false
    @Published private(set) var isOneClickInstalling = false
    @Published private(set) var stage = ""
    @Published private(set) var needsAccountSetup = false
    @Published private(set) var verifiedDeviceUDID: String?
    @Published private(set) var profileExpiry: Date?
    @Published private(set) var certificateExpiry: Date?
    @Published private(set) var installProgress = 0.0
    @Published private(set) var installSucceeded = false
    @Published var usesPersonalBundleID = false {
        didSet { if usesPersonalBundleID != oldValue { generation = UUID(); discardOutput() } }
    }
    @Published var personalBundleID = "" {
        didSet { if personalBundleID != oldValue { generation = UUID(); discardOutput() } }
    }
    @Published private(set) var isPreparingIdentifier = false
    @Published var deviceHost = "10.7.0.1" {
        didSet {
            if deviceHost != oldValue {
                if !syncingSettings, let settings, settings.host != deviceHost { settings.host = deviceHost; deviceHost = settings.host }
                installSucceeded = false
                verifiedDeviceUDID = nil
                generation = UUID()
            }
        }
    }
    @Published var error: String?
    private var ipaURL: URL?
    private var identityData: Data?
    private var isPEM = false
    private var pairingData: Data?
    private let settings: InstallationSettings?
    private var subscriptions = Set<AnyCancellable>()
    private var syncingSettings = false
    private let inspectBundleID: @Sendable (URL) throws -> String
    private var identifierTeam: String?
    private let installer: any IPAInstalling
    private let deviceProbe: any PairedDeviceProbing
    private let materialSigner: @MainActor (URL, ProvisioningMaterial) async throws -> URL
    private var generation = UUID()
    private var provisioningEngine: (any ProvisioningEngine)?
    private var outputIsProvisioned = false
    private var identifierTask: Task<String, Error>?

    init(settings: InstallationSettings? = nil, installer: any IPAInstalling = InstallCoordinator(), deviceProbe: any PairedDeviceProbing = ProvisioningDeviceProbe(),
         inspectBundleID: @escaping @Sendable (URL) throws -> String = { try ProvisioningIPAPreflight().inspect($0).bundleID },
         materialSigner: (@MainActor (URL, ProvisioningMaterial) async throws -> URL)? = nil) {
        self.settings = settings
        self.inspectBundleID = inspectBundleID
        self.installer = installer
        self.deviceProbe = deviceProbe
        self.materialSigner = materialSigner ?? Self.signProvisionedMaterial
        if let settings {
            deviceHost = settings.host
            settings.$pairing.sink { [weak self] saved in
                guard let self else { return }
                self.pairingData = saved?.data
                self.pairingName = saved?.name ?? "未选择"
                self.verifiedDeviceUDID = nil
                self.installSucceeded = false
                self.generation = UUID()
            }.store(in: &subscriptions)
            settings.$host.removeDuplicates().sink { [weak self] host in
                guard let self else { return }
                self.syncingSettings = true
                if self.deviceHost != host { self.deviceHost = host }
                self.syncingSettings = false
            }.store(in: &subscriptions)
            settings.$operationID.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
            error = settings.loadError
        }
    }

    static func signProvisionedMaterial(_ ipa: URL, _ material: ProvisioningMaterial) async throws -> URL {
        let profile = try ProfileParser.parse(material.profileData)
        return try await SigningEngine.shared.sign(ipaURL: ipa, identity: .pem(material.privateKeyPEM), profile: profile,
            restrictKeychainToApplication: true, signingBundleID: material.signingBundleID)
    }
    func suggestPersonalIdentifier(teamID: String) async {
        guard !busy,
              let ipaURL else { return }
        isPreparingIdentifier = true
        let operation = generation
        defer { isPreparingIdentifier = false; identifierTask = nil }
        do {
            let task = Task.detached(priority: .userInitiated) {
                let original = try ProvisioningIPAPreflight().inspect(ipaURL)
                return try ProvisioningSigningIdentifier.personal(original: original.bundleID, teamID: teamID)
            }
            identifierTask = task
            let identifier = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try check(operation)
            personalBundleID = identifier
            error = nil
        } catch { if generation == operation { self.error = safeMessage(error) } }
    }
    func verifyProvisioningDevice() async {
        guard !busy else { return }
        guard let pairingData else { error = "请先导入这台手机的配对文件"; return }
        let host = deviceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { error = "请输入手机本地 VPN 的设备地址"; return }
        generation = UUID()
        let operation = generation
        isProvisioning = true
        verifiedDeviceUDID = nil
        error = nil
        defer { isProvisioning = false }
        do {
            let udid = try await deviceProbe.deviceUDID(host: host, pairingData: pairingData)
            try check(operation)
            guard !udid.isEmpty else { throw ProvisioningError.materialInvalid("设备未返回标识") }
            verifiedDeviceUDID = udid
        } catch {
            if generation == operation { self.error = safeMessage(error) }
        }
    }
    private enum MaterialMode { case fresh, cached, install }

    func provisionAndSign(using engine: any ProvisioningEngine, account: ProvisioningAccount, teamID: String,
                          providerAccepted: Bool, useCachedMaterial: Bool = false,
                          confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool = { _ in false }) async {
        await perform(using: engine, account: account, teamID: teamID, canProvision: providerAccepted,
            mode: useCachedMaterial ? .cached : .fresh, confirmRevocation: confirmRevocation)
    }

    func installIPA(using engine: any ProvisioningEngine, account: ProvisioningAccount, teamID: String,
                    canProvision: Bool,
                    confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool = { _ in false }) async {
        await perform(using: engine, account: account, teamID: teamID, canProvision: canProvision,
            mode: .install, confirmRevocation: confirmRevocation)
    }

    private func perform(using engine: any ProvisioningEngine, account: ProvisioningAccount, teamID: String,
                         canProvision: Bool, mode: MaterialMode,
                         confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async {
        guard !busy else { return }
        needsAccountSetup = false
        guard mode != .fresh || canProvision else { error = "请先确认 Anisette 提供方及数据用途"; return }
        guard !teamID.isEmpty, account.teams.contains(where: { $0.id == teamID }) else {
            error = "请选择可用的免费 iOS 团队"; needsAccountSetup = true; return
        }
        guard let ipaURL, let pairingData else { error = "请先选择 IPA，并在首次设置中保存这台手机的配对文件"; return }
        let host = deviceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { error = "请输入手机本地 VPN 的设备地址"; return }
        let lock = settings?.beginOperation()
        generation = UUID()
        var operation = generation
        isProvisioning = true
        isOneClickInstalling = mode == .install
        provisioningEngine = engine
        error = nil
        discardOutput()
        defer {
            isProvisioning = false
            isInstalling = false
            isOneClickInstalling = false
            provisioningEngine = nil
            if let lock { settings?.endOperation(lock) }
        }
        do {
            stage = "正在检查 IPA…"
            var originalBundle: String?
            if mode == .install || settings != nil {
                let inspect = inspectBundleID
                let task = Task.detached(priority: .userInitiated) { try inspect(ipaURL) }
                identifierTask = task
                let original = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                identifierTask = nil
                try check(operation)
                originalBundle = original
                if identifierTeam != teamID {
                    // An explicit edit made before the first operation wins; later
                    // team changes restore only that team's saved selection.
                    if identifierTeam != nil || (!usesPersonalBundleID && personalBundleID.isEmpty) {
                        applySigningChoice(bundleID: original, teamID: teamID)
                    }
                    identifierTeam = teamID
                    operation = generation
                }
            }
            let target = usesPersonalBundleID ? try ProvisioningSigningIdentifier.validate(personalBundleID) : nil
            stage = "正在连接并验证配对设备…"
            let previousDevice = verifiedDeviceUDID
            let currentDevice = try await deviceProbe.deviceUDID(host: host, pairingData: pairingData)
            try check(operation)
            guard !currentDevice.isEmpty else { throw ProvisioningError.materialInvalid("设备未返回标识") }
            if let previousDevice, previousDevice != currentDevice {
                verifiedDeviceUDID = nil
                throw ProvisioningError.materialInvalid("配对设备已变化，请确认设备后重试")
            }
            verifiedDeviceUDID = currentDevice
            let request = ProvisioningRequest(accountID: account.id, teamID: teamID, ipaURL: ipaURL,
                deviceUDID: currentDevice, signingBundleID: target)
            stage = "正在检查本机签名材料…"
            let cached = mode == .fresh ? nil : try await engine.cachedMaterial(request: request)
            try check(operation)
            let material: ProvisioningMaterial
            if let cached { material = cached }
            else {
                if mode == .cached { throw ProvisioningError.materialInvalid("本机没有有效材料，请登录获取，或手动导入") }
                guard canProvision else { needsAccountSetup = true; throw ProvisioningError.invalidAccount }
                stage = "正在申请签名材料…"
                material = try await engine.provision(request: request, confirmRevocation: confirmRevocation)
            }
            try check(operation)
            stage = "正在签名 IPA…"
            let output = try await materialSigner(ipaURL, material)
            do { try check(operation) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
            guard FileManager.default.fileExists(atPath: output.path) else { throw LocSignError.signing("签名未生成文件") }
            outputURL = output
            outputIsProvisioned = true
            profileExpiry = material.profileExpiry
            certificateExpiry = material.certificateExpiry
            if let originalBundle {
                try settings?.saveSigningChoice(.init(personal: usesPersonalBundleID, identifier: target ?? ""),
                    bundleID: originalBundle, teamID: teamID)
            }
            if mode == .install {
                isProvisioning = false
                isInstalling = true
                stage = "正在上传并安装…"
                try await upload(output, host: host, pairing: pairingData, operation: operation)
                stage = "安装完成"
            } else { stage = "签名完成" }
        } catch {
            if generation == operation {
                if error as? ProvisioningError == .invalidAccount { needsAccountSetup = true }
                self.error = safeMessage(error)
                stage = error is CancellationError ? "已取消" : "操作未完成"
            }
        }
    }

    func restoreSigningIdentifier(teamID: String) async {
        guard !busy, let ipaURL, !teamID.isEmpty, identifierTeam != teamID else { return }
        isPreparingIdentifier = true
        let operation = generation
        defer { isPreparingIdentifier = false; identifierTask = nil }
        do {
            let inspect = inspectBundleID
            let task = Task.detached(priority: .userInitiated) { try inspect(ipaURL) }
            identifierTask = task
            let original = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try check(operation)
            applySigningChoice(bundleID: original, teamID: teamID)
            identifierTeam = teamID
        } catch { if generation == operation { self.error = safeMessage(error) } }
    }

    private func applySigningChoice(bundleID: String, teamID: String) {
        let choice = settings?.signingChoice(bundleID: bundleID, teamID: teamID)
        usesPersonalBundleID = choice?.personal ?? false
        personalBundleID = choice?.identifier ?? ""
    }

    private func upload(_ output: URL, host: String, pairing: Data, operation: UUID) async throws {
        try check(operation)
        try await installer.install(ipaURL: output, host: host, pairingData: pairing) { [weak self] value in
            await MainActor.run {
                guard let self, self.generation == operation else { return }
                self.installProgress = value
            }
        }
        try check(operation)
        installSucceeded = true
        installProgress = 1
    }

    func cancelProvisioning() async {
        generation = UUID()
        stage = "已取消"
        identifierTask?.cancel()
        let engine = provisioningEngine
        // Keep input locks until any in-flight signer has drained.
        await engine?.cancel()
    }
    func clearProvisioningOutput() {
        // Also invalidate a signer that may still be draining after cancellation.
        generation = UUID()
        if outputIsProvisioned { discardOutput() }
    }

    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard generation == operation else { throw CancellationError() }
    }
    private func safeMessage(_ failure: Error) -> String {
        if failure is CancellationError { return "操作已取消" }
        return ProvisioningRedaction.redact(failure.localizedDescription)
    }

    var busy: Bool {
        isSigning || isImporting || isInstalling || isProvisioning || isPreparingIdentifier || isOneClickInstalling || settings?.operationID != nil
    }
    var canInstall: Bool { ipaURL != nil && pairingData != nil && !busy }

    var canSign: Bool {
        ipaURL != nil && identityData != nil && profile != nil && !busy
    }

    func importFile(_ url: URL, as input: SigningInput) async {
        guard !busy else { return }
        isImporting = true
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            switch input {
            case .ipa:
                guard url.pathExtension.lowercased() == "ipa" else {
                    throw LocSignError.signing("请选择 .ipa 文件")
                }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).ipa")
                try await Task.detached(priority: .userInitiated) {
                    do {
                        try FileManager.default.copyItem(at: url, to: copy)
                    } catch {
                        try? FileManager.default.removeItem(at: copy)
                        throw error
                    }
                }.value
                if let previous = ipaURL { try? FileManager.default.removeItem(at: previous) }
                ipaURL = copy
                ipaName = url.lastPathComponent
                identifierTeam = nil
                usesPersonalBundleID = false
                personalBundleID = ""
            case .identity:
                let ext = url.pathExtension.lowercased()
                guard ["p12", "pfx", "pem"].contains(ext) else {
                    throw LocSignError.signing("请选择 P12 证书或 PEM 私钥")
                }
                let data = try readSmallFile(url)
                if ext == "pem" {
                    guard let key = String(data: data, encoding: .utf8), key.contains("PRIVATE KEY-----") else {
                        throw LocSignError.signing("PEM 文件中未找到私钥")
                    }
                }
                identityData = data
                isPEM = ext == "pem"
                needsPassword = !isPEM
                identityName = url.lastPathComponent
                password = ""
            case .profile:
                profile = try ProfileParser.parse(readSmallFile(url))
            case .pairing:
                guard url.pathExtension.lowercased() == "plist" else {
                    throw LocSignError.install("请选择配对 plist 文件")
                }
                let data = try readSmallFile(url)
                _ = try PairingRecord(data: data)
                try settings?.savePairing(data: data, name: url.lastPathComponent)
                pairingData = data
                verifiedDeviceUDID = nil
                generation = UUID()
                pairingName = url.lastPathComponent
                installSucceeded = false
            }
            if input != .pairing { discardOutput() }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func installSignedIPA() async {
        guard !busy, let outputURL, let pairingData else { return }
        let host = deviceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { error = "请输入手机上的本地 VPN 地址"; return }
        let lock = settings?.beginOperation()
        generation = UUID()
        let operation = generation
        isInstalling = true
        installProgress = 0
        installSucceeded = false
        error = nil
        defer { isInstalling = false; if let lock { settings?.endOperation(lock) } }
        do {
            try await upload(outputURL, host: host, pairing: pairingData, operation: operation)
        } catch { if generation == operation { self.error = safeMessage(error) } }
    }

    func sign() async {
        guard canSign, let ipaURL, let data = identityData, let profile else { return }
        isSigning = true
        error = nil
        discardOutput()
        defer { isSigning = false; password = "" }
        let identity: SigningIdentity
        if isPEM {
            guard let pem = String(data: data, encoding: .utf8) else {
                error = "私钥文件不是 UTF-8 文本"
                return
            }
            identity = .pem(pem)
        } else { identity = .pkcs12(data, password: password) }
        do {
            outputURL = try await SigningEngine.shared.sign(ipaURL: ipaURL, identity: identity, profile: profile)
        } catch { self.error = error.localizedDescription }
    }

    private func readSmallFile(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_485_760 else { throw LocSignError.signing("证书或描述文件超过 10 MB") }
        return try Data(contentsOf: url)
    }

    func discardOutput() {
        guard !isInstalling else { return }
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
        outputIsProvisioned = false
        profileExpiry = nil
        certificateExpiry = nil
        installProgress = 0
        installSucceeded = false
    }

    deinit {
        identifierTask?.cancel()
        if let ipaURL { try? FileManager.default.removeItem(at: ipaURL) }
    }
}
