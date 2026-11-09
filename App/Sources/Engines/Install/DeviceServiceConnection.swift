import Foundation

protocol DeviceServiceTransport: AnyObject {
    func sendPlist(_ value: [String: Any]) async throws
    func receivePlist() async throws -> [String: Any]
    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame
    func close()
}

final class DeviceServiceConnection: DeviceServiceTransport {
    private let queue = DispatchQueue(label: "com.locsign.device-service")
    private let socket: LSDeviceSocket
    private let encrypted: Bool

    init(host: String, endpoint: LockdownServiceEndpoint, pairing: PairingRecord,
         timeout: TimeInterval = 30) async throws {
        socket = try await Self.openSocket(host: host, endpoint: endpoint, pairing: pairing, timeout: timeout)
        encrypted = endpoint.enableSSL
    }

    func sendPlist(_ value: [String: Any]) async throws {
        try await perform {
            let data = try PlistFraming.encode(value)
            try self.send(data)
        }
    }

    func receivePlist() async throws -> [String: Any] {
        try await perform {
            let header = try self.read(length: 4)
            let size = header.reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= PlistFraming.maximumPayload else {
                throw LocSignError.install("设备服务返回无效的数据帧长度")
            }
            return try PlistFraming.decode(header + self.read(length: size))
        }
    }

    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame {
        try await perform {
            try self.send(frame.encoded())
            let header = try self.read(length: AFCFrame.headerLength)
            let total = Self.littleEndianUInt64(header, offset: 8)
            guard total >= UInt64(AFCFrame.headerLength),
                  total <= UInt64(AFCFrame.headerLength + AFCFrame.maximumPayload) else {
                throw LocSignError.install("AFC 响应长度无效")
            }
            let rest = try self.read(length: Int(total) - AFCFrame.headerLength)
            let response = try AFCFrame.decode(header + rest)
            guard response.packetNumber == frame.packetNumber else {
                throw LocSignError.install("AFC 响应序号不匹配")
            }
            return response
        }
    }

    func close() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        socket.interrupt()
        // Only shutdown runs concurrently with I/O. SecureTransport teardown
        // stays on the same serial queue as SSLRead/SSLWrite.
        queue.sync { socket.close() }
    }

    private func send(_ data: Data) throws {
        if encrypted { try socket.sendTLSData(data) }
        else { try socket.sendRawData(data) }
    }

    private func read(length: Int) throws -> Data {
        if encrypted { return try socket.readTLSLength(UInt(length)) }
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

    private static func littleEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    private static func openSocket(host: String, endpoint: LockdownServiceEndpoint,
                                   pairing: PairingRecord, timeout: TimeInterval) async throws -> LSDeviceSocket {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let socket = try LSDeviceSocket(host: host, port: endpoint.port, timeout: timeout)
                    do {
                        if endpoint.enableSSL {
                            let materials = try pairing.tlsIdentity()
                            try socket.startTLS(with: materials.identity,
                                                certificateChain: materials.certificateChain,
                                                trustedRoots: materials.trustRoots)
                        }
                    } catch {
                        socket.close()
                        throw error
                    }
                    continuation.resume(returning: socket)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
