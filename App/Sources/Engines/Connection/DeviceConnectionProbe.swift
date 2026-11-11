import Foundation
import Network

struct ConnectionProbeResult {
    let service: String
    let elapsed: TimeInterval
}

/// Read-only transport check. A successful QueryType is NOT pairing or installation.
final class DeviceConnectionProbe {
    func check(host: String, port: UInt16 = 62078, timeout: TimeInterval = 8) async throws -> ConnectionProbeResult {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("://"), !address.contains("/"), port > 0 else {
            throw LocSignError.install("请输入设备或本地 VPN 提供的 IP 地址")
        }
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw LocSignError.install("设备连接超时设置无效") }
        let session = ProbeSession(host: address, port: port, timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await session.run()
        }, onCancel: {
            session.cancel()
        })
    }
}

private final class ProbeSession {
    private let queue = DispatchQueue(label: "com.locsign.connection-probe")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<ConnectionProbeResult, Error>?
    private var timeout: DispatchWorkItem?
    private var decoder = PlistFrame.Decoder()
    private var finished = false
    private var cancelled = false
    private let started = Date()
    private let timeoutInterval: TimeInterval

    init(host: String, port: UInt16, timeout: TimeInterval) {
        timeoutInterval = timeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func run() async throws -> ConnectionProbeResult {
        try await withCheckedThrowingContinuation { pending in
            queue.async {
                self.continuation = pending
                if self.cancelled {
                    self.finish(.failure(CancellationError()))
                    return
                }
                let deadline = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(LocSignError.install("连接超时，请检查设备地址、本地 VPN 和本地网络权限")))
                }
                self.timeout = deadline
                self.queue.asyncAfter(deadline: .now() + self.timeoutInterval, execute: deadline)
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.sendQuery()
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            if self.continuation != nil { self.finish(.failure(CancellationError())) }
        }
    }

    private func sendQuery() {
        guard !finished else { return }
        do {
            let frame = try PlistFrame.encode(["Label": "LocSign", "Request": "QueryType"])
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { self.finish(.failure(error)) }
                else { self.receive() }
            })
        } catch { finish(.failure(error)) }
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            guard !self.finished else { return }
            do {
                if let data { try self.decoder.append(data) }
                if let response = try self.decoder.next() {
                    guard let service = response["Type"] as? String, service == "com.apple.mobile.lockdown" else {
                        throw LocSignError.install("目标未返回 Apple 设备连接服务")
                    }
                    self.finish(.success(ConnectionProbeResult(service: service, elapsed: Date().timeIntervalSince(self.started))))
                } else if let error { self.finish(.failure(error)) }
                else if complete { self.finish(.failure(LocSignError.install("设备在完整响应前关闭连接"))) }
                else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<ConnectionProbeResult, Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
