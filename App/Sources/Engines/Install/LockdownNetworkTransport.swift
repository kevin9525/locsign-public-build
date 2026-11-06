import Foundation

final class LockdownNetworkTransport: LockdownTransport {
    private let queue = DispatchQueue(label: "com.locsign.lockdown-transport")
    private let host: String
    private let socket: LSDeviceSocket
    private var isTLS = false

    init(host: String, port: UInt16 = 62078, timeout: TimeInterval = 8) async throws {
        guard !host.isEmpty, port > 0 else { throw LocSignError.install("设备地址无效") }
        self.host = host
        do {
            socket = try await Self.openSocket(host: host, port: port, timeout: timeout)
        } catch {
            throw LocSignError.install(error.localizedDescription)
        }
    }

    func send(_ request: [String: Any]) async throws {
        try await perform {
            let frame = try PlistFraming.encode(request)
            try self.write(frame)
        }
    }

    func receive() async throws -> [String: Any] {
        try await perform {
            let header = try self.read(length: 4)
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= PlistFraming.maximumPayload else {
                throw LocSignError.install("设备返回无效的数据帧长度")
            }
            let body = try self.read(length: length)
            return try PlistFraming.decode(header + body)
        }
    }

    func upgradeToTLS(using pairing: PairingRecord) async throws {
        let materials = try pairing.tlsIdentity()
        try await perform {
            try self.socket.startTLS(with: materials.identity,
                                     certificateChain: materials.certificateChain,
                                     trustedRoots: materials.trustRoots)
            self.isTLS = true
        }
    }

    func openService(_ endpoint: LockdownServiceEndpoint, pairing: PairingRecord,
                     timeout: TimeInterval = 30) async throws -> DeviceServiceConnection {
        try await DeviceServiceConnection(host: host, endpoint: endpoint, pairing: pairing, timeout: timeout)
    }

    func close() {
        queue.async { self.socket.close() }
    }

    private func write(_ data: Data) throws {
        if isTLS { try socket.sendTLSData(data) }
        else { try socket.sendRawData(data) }
    }

    private func read(length: Int) throws -> Data {
        if isTLS { return try socket.readTLSLength(UInt(length)) }
        return try socket.readRawLength(UInt(length))
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func openSocket(host: String, port: UInt16, timeout: TimeInterval) async throws -> LSDeviceSocket {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try LSDeviceSocket(host: host, port: port, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
