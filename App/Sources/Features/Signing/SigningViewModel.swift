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
    @Published private(set) var verifiedDeviceUDID: String?
    @Published private(set) var profileExpiry: Date?
    @Published private(set) var certificateExpiry: Date?
    @Published private(set) var installProgress = 0.0
    @Published private(set) var installSucceeded = false
    @Published var deviceHost = "" {
        didSet {
            if deviceHost != oldValue {
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
    private let installer: any IPAInstalling
    private let deviceProbe: any PairedDeviceProbing
    private let materialSigner: @MainActor (URL, ProvisioningMaterial) async throws -> URL
    private var generation = UUID()
    private var provisioningEngine: (any ProvisioningEngine)?

    init(installer: any IPAInstalling = InstallCoordinator(), deviceProbe: any PairedDeviceProbing = ProvisioningDeviceProbe(),
         materialSigner: (@MainActor (URL, ProvisioningMaterial) async throws -> URL)? = nil) {
        self.installer = installer
        self.deviceProbe = deviceProbe
        self.materialSigner = materialSigner ?? Self.signProvisionedMaterial
    }

    static func signProvisionedMaterial(_ ipa: URL, _ material: ProvisioningMaterial) async throws -> URL {
        let profile = try ProfileParser.parse(material.profileData)
        return try await SigningEngine.shared.sign(ipaURL: ipa, identity: .pem(material.privateKeyPEM), profile: profile)
    }
    func verifyProvisioningDevice() async {
        guard !isSigning, !isImporting, !isInstalling, !isProvisioning else { return }
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
    func provisionAndSign(using engine: any ProvisioningEngine, account: ProvisioningAccount, teamID: String,
                          providerAccepted: Bool,
                          useCachedMaterial: Bool = false,
                          confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool = { _ in false }) async {
        guard !isSigning, !isImporting, !isInstalling, !isProvisioning else { return }
        guard providerAccepted else { error = "请先确认 Anisette 提供方及数据用途"; return }
        guard !teamID.isEmpty, account.teams.contains(where: { $0.id == teamID }) else { error = "请选择可用的免费 iOS 团队"; return }
        guard let ipaURL, let pairingData, let verifiedDeviceUDID else { error = "请导入 IPA、配对文件并检测已配对设备"; return }
        let host = deviceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        generation = UUID()
        let operation = generation
        isProvisioning = true
        provisioningEngine = engine
        error = nil
        discardOutput()
        defer {
            isProvisioning = false
            provisioningEngine = nil
        }
        do {
            let currentDevice = try await deviceProbe.deviceUDID(host: host, pairingData: pairingData)
            try check(operation)
            guard currentDevice == verifiedDeviceUDID else {
                self.verifiedDeviceUDID = nil
                throw ProvisioningError.materialInvalid("配对设备已变化，请重新检测")
            }
            let material = try await engine.provision(request: .init(accountID: account.id, teamID: teamID, ipaURL: ipaURL,
                deviceUDID: currentDevice), confirmRevocation: confirmRevocation)
            try check(operation)
            let output = try await materialSigner(ipaURL, material)
            do { try check(operation) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
            guard FileManager.default.fileExists(atPath: output.path) else { throw LocSignError.signing("签名未生成文件") }
            outputURL = output
            profileExpiry = material.profileExpiry
            certificateExpiry = material.certificateExpiry
        } catch {
            if generation == operation { self.error = safeMessage(error) }
        }
    }
    func cancelProvisioning() async {
        generation = UUID()
        let engine = provisioningEngine
        // Keep input locks until any in-flight signer has drained.
        await engine?.cancel()
    }
    func clearProvisioningOutput() {}

    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard generation == operation else { throw CancellationError() }
    }
    private func safeMessage(_ failure: Error) -> String {
        if failure is CancellationError { return "操作已取消" }
        return ProvisioningRedaction.redact(failure.localizedDescription)
    }

    var canSign: Bool {
        ipaURL != nil && identityData != nil && profile != nil && !isSigning && !isImporting && !isInstalling && !isProvisioning
    }

    func importFile(_ url: URL, as input: SigningInput) async {
        guard !isSigning, !isImporting, !isInstalling, !isProvisioning else { return }
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
        guard !isInstalling, !isSigning, !isImporting, !isProvisioning, let outputURL, let pairingData else { return }
        let host = deviceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { error = "请输入手机上的本地 VPN 地址"; return }
        isInstalling = true
        installProgress = 0
        installSucceeded = false
        error = nil
        defer { isInstalling = false }
        do {
            try await installer.install(ipaURL: outputURL, host: host,
                                                    pairingData: pairingData) { [weak self] value in
                await MainActor.run { self?.installProgress = value }
            }
            installSucceeded = true
            installProgress = 1
        } catch { self.error = error.localizedDescription }
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
        profileExpiry = nil
        certificateExpiry = nil
        installProgress = 0
        installSucceeded = false
    }

    deinit {
        if let ipaURL { try? FileManager.default.removeItem(at: ipaURL) }
    }
}
