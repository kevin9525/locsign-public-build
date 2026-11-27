import Foundation
import Network

struct PairedDeviceProbeResult {
    let deviceUDID: String
    let elapsed: TimeInterval
}

enum PairedProbeStage: String, Equatable {
    case pairingFile, authentication, fileService, installationService

    var title: String {
        switch self {
        case .pairingFile: return "读取配对文件"
        case .authentication: return "设备连接与配对认证"
        case .fileService: return "文件传输服务"
        case .installationService: return "安装服务"
        }
    }
}

typealias PairedProbeProgress = @MainActor (PairedProbeStage, Bool) async -> Void

/// Authenticates the device and opens/closes the two installation services.
/// It never uploads a file or sends an installation command.
final class PairedDeviceProbe {
    private let makeTransport: (String) async throws -> any LockdownTransport
    private let verifyService: (String, LockdownServiceEndpoint, PairingRecord) async throws -> Void

    init(makeTransport: @escaping (String) async throws -> any LockdownTransport = {
        try await LockdownNetworkTransport(host: $0)
    }, verifyService: @escaping (String, LockdownServiceEndpoint, PairingRecord) async throws -> Void = {
        host, endpoint, pairing in
        let connection = try await DeviceServiceConnection(host: host, endpoint: endpoint, pairing: pairing, timeout: 8)
        connection.close()
    }) {
        self.makeTransport = makeTransport
        self.verifyService = verifyService
    }

    func check(host: String, pairingData: Data,
               progress: @escaping PairedProbeProgress = { _, _ in }) async throws -> PairedDeviceProbeResult {
        try Task.checkCancellation()
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else {
            throw LocSignError.install("请输入设备 IP 地址")
        }
        let started = Date()
        var stage = PairedProbeStage.pairingFile
        do {
            await progress(stage, false)
            try Task.checkCancellation()
            let pairing = try PairingRecord(data: pairingData)
            _ = try pairing.tlsIdentity()
            try Task.checkCancellation()
            await progress(stage, true)
            try Task.checkCancellation()
            stage = .authentication
            await progress(stage, false)
            try Task.checkCancellation()
            let transport = try await makeTransport(address)
            let session = LockdownSession(transport: transport, pairing: pairing)
            defer { session.close() }
            try Task.checkCancellation()
            try await session.start()
            try Task.checkCancellation()
            let deviceID = try await session.queryUniqueDeviceID()
            try Task.checkCancellation()
            await progress(stage, true)
            try Task.checkCancellation()

            for (name, serviceStage) in [("com.apple.afc", PairedProbeStage.fileService),
                                         ("com.apple.mobile.installation_proxy", .installationService)] {
                stage = serviceStage
                await progress(stage, false)
                try Task.checkCancellation()
                let endpoint = try await session.startService(name)
                try Task.checkCancellation()
                try await verifyService(address, endpoint, pairing)
                try Task.checkCancellation()
                await progress(stage, true)
                try Task.checkCancellation()
            }
            return PairedDeviceProbeResult(deviceUDID: deviceID, elapsed: Date().timeIntervalSince(started))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PairedProbeFailure(stage: stage, detail: ProvisioningRedaction.redact(error.localizedDescription))
        }
    }
}

struct PairedProbeFailure: LocalizedError {
    let stage: PairedProbeStage
    let detail: String
    var errorDescription: String? { "\(stage.title)未通过：\(detail)" }
}
