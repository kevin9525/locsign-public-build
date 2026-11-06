import Foundation

enum LockdownPhase: Equatable {
    case disconnected
    case queried
    case sessionStarted
    case tlsRequired
    case ready
}

struct LockdownServiceEndpoint: Equatable {
    let port: UInt16
    let enableSSL: Bool
}

protocol LockdownTransport: AnyObject {
    func send(_ request: [String: Any]) async throws
    func receive() async throws -> [String: Any]
    func upgradeToTLS(using pairing: PairingRecord) async throws
    func close()
}

enum LockdownProtocol {
    static func queryType() -> [String: Any] {
        ["Label": "LocSign", "Request": "QueryType"]
    }

    static func startSession(pairing: PairingRecord) -> [String: Any] {
        ["Label": "LocSign", "Request": "StartSession",
         "HostID": pairing.hostID, "SystemBUID": pairing.systemBUID]
    }
}

/// Lockdownd's protocol state machine. Network transport is injected so the
/// handshake can be verified without a device and the TLS upgrade remains a
/// single explicit boundary in the production adapter.
final class LockdownSession {
    private(set) var phase: LockdownPhase = .disconnected
    private(set) var deviceUDID: String?
    private let transport: LockdownTransport
    private let pairing: PairingRecord

    init(transport: LockdownTransport, pairing: PairingRecord) {
        self.transport = transport
        self.pairing = pairing
    }

    func start() async throws {
        do {
            try await transport.send(LockdownProtocol.queryType())
            let query = try await transport.receive()
            guard query["Type"] as? String == "com.apple.mobile.lockdown" else {
                throw LocSignError.install("目标未返回 Apple 设备连接服务")
            }
            phase = .queried

            try await transport.send(LockdownProtocol.startSession(pairing: pairing))
            let session = try await transport.receive()
            try Self.requireSuccess(session, operation: "启动设备会话")
            guard let sessionID = session["SessionID"] as? String, !sessionID.isEmpty,
                  session["EnableSessionSSL"] as? Bool == true else {
                throw LocSignError.install("设备未建立受 TLS 保护的配对会话")
            }
            phase = .sessionStarted

            phase = .tlsRequired
            try await transport.upgradeToTLS(using: pairing)
            phase = .ready
        } catch {
            phase = .disconnected
            transport.close()
            throw error
        }
    }

    func queryUniqueDeviceID() async throws -> String {
        guard phase == .ready else { throw LocSignError.install("设备会话尚未建立") }
        try await transport.send(["Label": "LocSign", "Request": "GetValue", "Key": "UniqueDeviceID"])
        let response = try await transport.receive()
        try Self.requireSuccess(response, operation: "读取设备标识")
        guard let value = response["Value"] as? String, !value.isEmpty else {
            throw LocSignError.install("设备未返回 UniqueDeviceID")
        }
        deviceUDID = value
        return value
    }

    func startService(_ name: String) async throws -> LockdownServiceEndpoint {
        guard phase == .ready else { throw LocSignError.install("设备会话尚未建立") }
        try await transport.send(["Label": "LocSign", "Request": "StartService", "Service": name])
        let response = try await transport.receive()
        try Self.requireSuccess(response, operation: "启动 \(name)")
        guard let port = response["Port"] as? Int, (1...Int(UInt16.max)).contains(port) else {
            throw LocSignError.install("设备未返回 \(name) 端口")
        }
        return LockdownServiceEndpoint(port: UInt16(port), enableSSL: response["EnableServiceSSL"] as? Bool ?? false)
    }

    func close() {
        transport.close()
        phase = .disconnected
    }

    private static func requireSuccess(_ response: [String: Any], operation: String) throws {
        if let error = response["Error"] as? String {
            throw LocSignError.install("\(operation)失败：\(error)")
        }
    }
}
