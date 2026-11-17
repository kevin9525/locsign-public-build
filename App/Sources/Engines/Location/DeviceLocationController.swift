import Foundation
import CryptoKit
import Network

struct LocationCoordinate: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw LocationControlError.message("纬度须在 -90 到 90，经度须在 -180 到 180 之间，且必须是有限数值。")
        }
        self.latitude = latitude
        self.longitude = longitude
    }
}

enum LocationControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Only a failure from the latest explicit request may invalidate its session.
struct LocationFailureRevision {
    private(set) var current = UUID()
    mutating func advance() { current = UUID() }
    func accepts(_ revision: UUID) -> Bool { revision == current }
}

@MainActor
protocol DeviceLocationControlling: AnyObject {
    var onSessionFailure: (@Sendable (String) -> Void)? { get set }
    func prepareConnection(host: String, timeout: TimeInterval) async throws
    func set(_ coordinate: LocationCoordinate, host: String, pairingData: Data) async throws
    func clear(host: String, pairingData: Data) async throws
    func disconnect() async
}

@MainActor
final class DeviceLocationController: DeviceLocationControlling {
    var onSessionFailure: (@Sendable (String) -> Void)?
    private let worker = LocationSessionWorker()
    private let makeTransport: (String, TimeInterval) async throws -> any LocationLockdownTransport
    private let openService: (String, LockdownServiceEndpoint, PairingRecord) async throws -> any DeviceServiceTransport
    private var preparedTransport: (host: String, transport: any LocationLockdownTransport)?
    private var heartbeat: DeviceHeartbeat?
    private var lockdown: LockdownSession?
    private var identity: String?
    private var nativePairingData: Data?
    private var generation = UUID()
    private var failureRevision = LocationFailureRevision()
    private var busy = false

    init(makeTransport: @escaping (String, TimeInterval) async throws -> any LocationLockdownTransport = {
        try await LockdownNetworkTransport(host: $0, connectTimeout: $1)
    }, openService: @escaping (String, LockdownServiceEndpoint, PairingRecord) async throws -> any DeviceServiceTransport = {
        try await DeviceServiceConnection(host: $0, endpoint: $1, pairing: $2)
    }) {
        self.makeTransport = makeTransport; self.openService = openService
    }

    /// Reserve the actual socket for the forthcoming authenticated session.
    /// TCP readiness alone does not authorize a device operation; start() still
    /// performs QueryType, StartSession and pairing TLS on this same transport.
    func prepareConnection(host: String, timeout: TimeInterval) async throws {
        guard !busy else { throw LocationControlError.message("定位操作尚未结束，请稍候。") }
        busy = true
        defer { busy = false }
        let address = try Self.address(host)
        await disconnect()
        let revision = generation
        try Task.checkCancellation()
        let transport = try await makeTransport(address, timeout)
        do {
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            preparedTransport = (address, transport)
        } catch { transport.close(); throw error }
    }

    func set(_ coordinate: LocationCoordinate, host: String, pairingData: Data) async throws {
        guard !busy else { throw LocationControlError.message("定位操作尚未结束，请稍候。") }
        failureRevision.advance()
        busy = true
        defer { busy = false }
        do {
            let (heartbeat, nativePairing) = try await connect(host: host, pairingData: pairingData)
            let operationGeneration = generation
            let revision = failureRevision.current
            try Task.checkCancellation()
            try await worker.set(coordinate, host: host, pairingData: nativePairing,
                                 ddiDirectory: Bundle.main.url(forResource: "LocationDDI", withExtension: nil),
                                 healthCheck: { try heartbeat.check() }, onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == operationGeneration,
                          self.failureRevision.accepts(revision) else { return }
                    self.onSessionFailure?(message)
                    await self.disconnect()
                }
            })
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
        } catch {
            await disconnect()
            throw error
        }
    }

    func clear(host: String, pairingData: Data) async throws {
        guard !busy else { throw LocationControlError.message("定位操作尚未结束，请稍候。") }
        failureRevision.advance()
        busy = true
        defer { busy = false }
        do {
            let (heartbeat, nativePairing) = try await connect(host: host, pairingData: pairingData)
            let operationGeneration = generation
            try Task.checkCancellation()
            try await worker.clear(host: host, pairingData: nativePairing,
                                   ddiDirectory: Bundle.main.url(forResource: "LocationDDI", withExtension: nil),
                                   healthCheck: { try heartbeat.check() })
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            await disconnect()
        } catch {
            await disconnect()
            throw error
        }
    }

    func disconnect() async {
        generation = UUID()
        failureRevision.advance()
        identity = nil
        nativePairingData = nil
        let prepared = preparedTransport
        preparedTransport = nil
        prepared?.transport.close()
        // Detach before awaiting: an older disconnect must not close a newer session.
        let previousHeartbeat = heartbeat
        let previousLockdown = lockdown
        heartbeat = nil
        lockdown = nil
        // Worker waits for any active native call before releasing its handles.
        await worker.disconnect()
        await previousHeartbeat?.stop()
        previousLockdown?.close()
    }

    private func connect(host: String, pairingData: Data) async throws -> (DeviceHeartbeat, Data) {
        let host = try Self.address(host)
        let key = host + ":" + SHA256.hash(data: pairingData).map { String(format: "%02x", $0) }.joined()
        if identity == key, let heartbeat, let nativePairingData {
            try heartbeat.check()
            return (heartbeat, nativePairingData)
        }
        let prepared = preparedTransport
        preparedTransport = nil
        await disconnect()
        let currentGeneration = generation
        var stage = "L00 读取配对文件"
        do {
            let pairing = try PairingRecord(data: pairingData)
            try Task.checkCancellation()
            stage = "L01 连接设备控制端口 62078"
            let transport: any LocationLockdownTransport
            if let prepared, prepared.host == host { transport = prepared.transport }
            else {
                prepared?.transport.close()
                transport = try await makeTransport(host, 8)
            }
            let session = LockdownSession(transport: transport, pairing: pairing)
            lockdown = session
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            stage = "L02 配对认证"
            try await session.start()
            stage = "L03 校验定位设备证书"
            let peerCertificate = try await transport.authenticatedPeerCertificate()
            let nativePairing = try LocationPairingRecord.prepare(pairingData, authenticatedDeviceCertificate: peerCertificate)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            stage = "L04 读取设备身份"
            _ = try await session.queryUniqueDeviceID()
            stage = "L05 启动设备保活服务"
            let endpoint = try await session.startService("com.apple.mobile.heartbeat")
            stage = "L06 连接设备保活端口 \(endpoint.port)"
            let connection = try await openService(host, endpoint, pairing)
            let heartbeat = DeviceHeartbeat(connection: connection)
            self.heartbeat = heartbeat
            stage = "L07 建立设备保活"
            try await heartbeat.start()
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            identity = key
            nativePairingData = nativePairing
            return (heartbeat, nativePairing)
        } catch {
            prepared?.transport.close()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw LocationControlError.message("\(stage)失败：\(error.localizedDescription)")
        }
    }

    private static func address(_ host: String) throws -> String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(value) != nil || IPv6Address(value) != nil else {
            throw LocationControlError.message("请输入有效的设备 IP 地址。")
        }
        return value
    }
}
