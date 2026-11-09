import Foundation
import Combine

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published var host = "10.7.0.1" {
        didSet {
            if host != oldValue {
                if !syncingSettings, let settings, settings.host != host { settings.host = host; host = settings.host }
                clearResult()
            }
        }
    }
    @Published private(set) var isChecking = false
    @Published private(set) var message = ""
    @Published private(set) var reachable = false
    @Published private(set) var pairingName = "未选择"
    @Published private(set) var pairedResult: PairedDeviceProbeResult?
    private var pairingData: Data?
    private let settings: InstallationSettings?
    private var subscriptions = Set<AnyCancellable>()
    private var syncingSettings = false
    private let reachabilityCheck: (String) async throws -> ConnectionProbeResult
    private let pairingCheck: (String, Data) async throws -> PairedDeviceProbeResult

    init(settings: InstallationSettings? = nil, checkReachability: @escaping (String) async throws -> ConnectionProbeResult = {
        try await DeviceConnectionProbe().check(host: $0)
    }, checkPairing: @escaping (String, Data) async throws -> PairedDeviceProbeResult = {
        try await PairedDeviceProbe().check(host: $0, pairingData: $1)
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
            if let error = settings.loadError { message = error }
        }
    }

    var deviceBusy: Bool { isChecking || settings?.operationID != nil }
    var canCheckPairing: Bool { pairingData != nil && !deviceBusy && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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

    func checkReachability() async {
        guard !deviceBusy else { return }
        let lock = settings?.beginOperation()
        defer { if let lock { settings?.endOperation(lock) } }
        clearResult()
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await reachabilityCheck(host)
            try Task.checkCancellation()
            reachable = true
            message = String(format: "设备服务已响应（%.2f 秒）。可继续验证配对。", result.elapsed)
        } catch is CancellationError { message = "已取消检测" }
        catch { message = error.localizedDescription }
    }

    func checkPairing() async {
        guard canCheckPairing, let pairingData else { return }
        let lock = settings?.beginOperation()
        defer { if let lock { settings?.endOperation(lock) } }
        clearResult()
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await pairingCheck(host, pairingData)
            try Task.checkCancellation()
            pairedResult = result
            message = String(format: "配对和服务连接检查完成（%.2f 秒）。", result.elapsed)
        } catch is CancellationError { message = "已取消检查" }
        catch { message = error.localizedDescription }
    }

    func reportImportError(_ error: Error) {
        clearResult()
        message = error.localizedDescription
    }

    private func clearResult() {
        reachable = false
        pairedResult = nil
        message = ""
    }
}
