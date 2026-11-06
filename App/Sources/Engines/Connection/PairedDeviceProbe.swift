import Foundation
import Network

struct PairedDeviceProbeResult {
    let deviceUDID: String
    let elapsed: TimeInterval
}

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

    func check(host: String, pairingData: Data) async throws -> PairedDeviceProbeResult {
        try Task.checkCancellation()
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else {
            throw LocSignError.install("请输入设备 IP 地址")
        }
        let started = Date()
        var stage = "读取配对文件"
        do {
            let pairing = try PairingRecord(data: pairingData)
            _ = try pairing.tlsIdentity()
            try Task.checkCancellation()
            stage = "连接设备"
            let transport = try await makeTransport(address)
            let session = LockdownSession(transport: transport, pairing: pairing)
            defer { session.close() }
            try Task.checkCancellation()
            stage = "配对认证"
            try await session.start()
            try Task.checkCancellation()
            let deviceID = try await session.queryUniqueDeviceID()
            try Task.checkCancellation()

            for (name, label) in [("com.apple.afc", "文件传输服务"),
                                  ("com.apple.mobile.installation_proxy", "安装服务")] {
                stage = label
                let endpoint = try await session.startService(name)
                try Task.checkCancellation()
                try await verifyService(address, endpoint, pairing)
                try Task.checkCancellation()
            }
            return PairedDeviceProbeResult(deviceUDID: deviceID, elapsed: Date().timeIntervalSince(started))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PairedProbeFailure(stage: stage, detail: error.localizedDescription)
        }
    }
}

private struct PairedProbeFailure: LocalizedError {
    let stage: String
    let detail: String
    var errorDescription: String? { "\(stage)未通过：\(detail)" }
}
