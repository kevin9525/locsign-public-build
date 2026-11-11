import Foundation
import CryptoKit

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
    func set(_ coordinate: LocationCoordinate, host: String, pairingData: Data) async throws
    func clear(host: String, pairingData: Data) async throws
    func disconnect() async
}

@MainActor
final class DeviceLocationController: DeviceLocationControlling {
    var onSessionFailure: (@Sendable (String) -> Void)?
    private let worker = LocationSessionWorker()
    private var heartbeat: DeviceHeartbeat?
    private var lockdown: LockdownSession?
    private var identity: String?
    private var nativePairingData: Data?
    private var generation = UUID()
    private var failureRevision = LocationFailureRevision()
    private var busy = false

    init() { }

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
        let key = host + ":" + SHA256.hash(data: pairingData).map { String(format: "%02x", $0) }.joined()
        if identity == key, let heartbeat, let nativePairingData {
            try heartbeat.check()
            return (heartbeat, nativePairingData)
        }
        await disconnect()
        let currentGeneration = generation
        let pairing = try PairingRecord(data: pairingData)
        let transport = try await LockdownNetworkTransport(host: host)
        let session = LockdownSession(transport: transport, pairing: pairing)
        lockdown = session
        try await session.start()
        let peerCertificate = try await transport.authenticatedPeerCertificate()
        let prepared = try LocationPairingRecord.prepare(pairingData, authenticatedDeviceCertificate: peerCertificate)
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        _ = try await session.queryUniqueDeviceID()
        let endpoint = try await session.startService("com.apple.mobile.heartbeat")
        let connection = try await DeviceServiceConnection(host: host, endpoint: endpoint, pairing: pairing)
        let heartbeat = DeviceHeartbeat(connection: connection)
        self.heartbeat = heartbeat
        try await heartbeat.start()
        guard generation == currentGeneration else { throw CancellationError() }
        identity = key
        nativePairingData = prepared
        return (heartbeat, prepared)
    }
}
