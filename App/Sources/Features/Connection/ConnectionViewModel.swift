import Foundation
import Combine
import Network

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published var host = "10.7.0.1" {
        didSet {
            if host != oldValue {
                if !syncingSettings, let settings, settings.host != host {
                    if settings.operationID != nil { host = oldValue; return }
                    settings.updateHost(host)
                }
                clearResult()
            }
        }
    }
    @Published private(set) var isChecking = false
    @Published private(set) var message = ""
    @Published private(set) var reachable = false
    @Published private(set) var pairingName = "未选择"
    @Published private(set) var pairedResult: PairedDeviceProbeResult?
    @Published private(set) var steps: [ConnectionCheckStep: ConnectionCheckState] = [:]
    @Published private(set) var failedStep: ConnectionCheckStep?
    @Published private(set) var checkedAt: Date?
    private var resultID = UUID()
    private var pairingData: Data?
    private let settings: InstallationSettings?
    private var subscriptions = Set<AnyCancellable>()
    private var syncingSettings = false
    private let reachabilityCheck: (String) async throws -> ConnectionProbeResult
    private let pairingCheck: (String, Data, @escaping PairedProbeProgress) async throws -> PairedDeviceProbeResult

    init(settings: InstallationSettings? = nil, checkReachability: @escaping (String) async throws -> ConnectionProbeResult = {
        try await DeviceConnectionProbe().check(host: $0)
    }, checkPairing: @escaping (String, Data, @escaping PairedProbeProgress) async throws -> PairedDeviceProbeResult = {
        try await PairedDeviceProbe().check(host: $0, pairingData: $1, progress: $2)
    }) {
        self.reachabilityCheck = checkReachability
        self.pairingCheck = checkPairing
        self.settings = settings
        if let settings {
            host = settings.host
            settings.$pairing.sink { [weak self] saved in
                self?.pairingData = saved?.data
                self?.pairingName = saved?.name ?? "未选择"
                self?.clearResult()
            }.store(in: &subscriptions)
            settings.$host.removeDuplicates().sink { [weak self] host in
                guard let self else { return }
                self.syncingSettings = true
                if self.host != host { self.host = host }
                self.syncingSettings = false
            }.store(in: &subscriptions)
            settings.$operationID.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
            if let error = settings.loadError { message = ProvisioningRedaction.redact(error) }
        }
    }

    var deviceBusy: Bool { isChecking || settings?.operationID != nil }
    var canRunSelfCheck: Bool { !deviceBusy }
    var canCheckPairing: Bool { pairingData != nil && !deviceBusy && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func state(for step: ConnectionCheckStep) -> ConnectionCheckState { steps[step] ?? .pending }

    func importPairing(_ url: URL) throws {
        guard !deviceBusy else { return }
        clearResult()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "plist" else {
            throw LocSignError.install("请选择设备配对 plist 文件")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_485_760 else { throw LocSignError.install("配对文件超过 10 MB") }
        let data = try Data(contentsOf: url)
        _ = try PairingRecord(data: data)
        try settings?.savePairing(data: data, name: url.lastPathComponent)
        pairingData = data
        pairingName = url.lastPathComponent
    }

    func checkReachability() async { await runCheck(includePairing: false) }

    /// One check holds the shared device lock across reachability and authentication.
    func checkPairing() async { await runCheck(includePairing: true) }

    private func runCheck(includePairing: Bool) async {
        guard !deviceBusy else { return }
        let lock = settings?.beginOperation()
        guard settings == nil || lock != nil else { return }
        clearResult()
        let id = resultID
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = pairingData
        let pairingLoadError = settings?.loadError
        isChecking = true
        defer {
            isChecking = false
            if let lock { settings?.endOperation(lock) }
        }
        var activeStep = ConnectionCheckStep.address
        steps[activeStep] = .checking
        AppLogger.log(.info, "connection", includePairing ? "开始连接自检" : "开始设备响应检查")
        do {
            try Task.checkCancellation()
            guard IPv4Address(address) != nil || IPv6Address(address) != nil else {
                throw LocSignError.install("请输入有效的设备 IP 地址")
            }
            steps[.address] = .passed
            activeStep = .reachability
            steps[activeStep] = .checking
            let response = try await reachabilityCheck(address)
            try Task.checkCancellation()
            guard resultID == id else { return }
            reachable = true
            steps[.reachability] = .passed
            if includePairing {
                activeStep = .pairingFile
                steps[activeStep] = .checking
                if let pairingLoadError { throw LocSignError.install(pairingLoadError) }
                guard let data else { throw LocSignError.install("设备服务已响应，请先导入这台手机的配对文件") }
                let result = try await pairingCheck(address, data) { [weak self] stage, passed in
                    guard let self, self.resultID == id, self.isChecking, !Task.isCancelled else { return }
                    let step = ConnectionCheckStep(stage)
                    activeStep = step
                    self.steps[step] = passed ? .passed : .checking
                }
                try Task.checkCancellation()
                guard resultID == id else { return }
                pairedResult = result
                for step in ConnectionCheckStep.allCases { steps[step] = .passed }
                message = String(format: "本次自检通过（%.2f 秒）：配对认证与安装服务连接正常。", response.elapsed + result.elapsed)
            } else {
                skipPendingSteps()
                message = String(format: "设备服务已响应（%.2f 秒），配对和安装服务尚未检查。", response.elapsed)
            }
            checkedAt = Date()
            AppLogger.log(.info, "connection", message)
        } catch {
            guard resultID == id else { return }
            let cancelled = error is CancellationError || Task.isCancelled
            let failed = (error as? PairedProbeFailure).map { ConnectionCheckStep($0.stage) }
                ?? ConnectionCheckStep.allCases.first(where: { steps[$0] == .checking }) ?? activeStep
            steps[failed] = cancelled ? .cancelled : .failed
            failedStep = cancelled ? nil : failed
            pairedResult = nil
            skipPendingSteps()
            message = cancelled ? "检查已取消，未完成本次自检。" : ProvisioningRedaction.redact(error.localizedDescription)
            checkedAt = Date()
            AppLogger.log(cancelled ? .info : .warn, "connection", failed.title + "：" + message)
        }
    }

    func reportImportError(_ error: Error) {
        clearResult()
        failedStep = .pairingFile
        message = ProvisioningRedaction.redact(error.localizedDescription)
    }

    private func clearResult() {
        resultID = UUID()
        reachable = false
        pairedResult = nil
        steps = [:]
        failedStep = nil
        checkedAt = nil
        message = ""
    }

    private func skipPendingSteps() {
        for step in ConnectionCheckStep.allCases where state(for: step) == .pending || state(for: step) == .checking {
            steps[step] = .skipped
        }
    }
}
