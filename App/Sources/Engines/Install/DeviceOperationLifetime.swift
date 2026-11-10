import Foundation

/// Owns the connections of one device operation, including connections whose
/// asynchronous open completes after cancellation has already closed the scope.
final class DeviceOperationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var actions: [() -> Void] = []

    func own(_ transport: any LockdownTransport) -> any LockdownTransport {
        let connection = OperationLockdownConnection(transport)
        register { connection.close() }
        return connection
    }

    func own(_ transport: any DeviceServiceTransport) -> any DeviceServiceTransport {
        let connection = OperationServiceConnection(transport)
        register { connection.close() }
        return connection
    }

    private func register(_ action: @escaping () -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            action()
        } else {
            actions.append(action)
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let actions = self.actions.reversed()
        self.actions.removeAll()
        lock.unlock()
        for action in actions { action() }
    }
}

/// The session and heartbeat also close on errors. Only one caller may perform
/// the physical close; TLS teardown remains in the transport's own serial queue.
private final class OperationCloseOnce {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func close() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

private final class OperationLockdownConnection: LockdownTransport {
    private let transport: any LockdownTransport
    private let closer: OperationCloseOnce
    init(_ transport: any LockdownTransport) {
        self.transport = transport
        closer = OperationCloseOnce { transport.close() }
    }
    func send(_ request: [String: Any]) async throws {
        try Task.checkCancellation()
        try await transport.send(request)
        try Task.checkCancellation()
    }
    func receive() async throws -> [String: Any] {
        try Task.checkCancellation()
        let response = try await transport.receive()
        try Task.checkCancellation()
        return response
    }
    func upgradeToTLS(using pairing: PairingRecord) async throws {
        try Task.checkCancellation()
        try await transport.upgradeToTLS(using: pairing)
        try Task.checkCancellation()
    }
    func close() { closer.close() }
}

private final class OperationServiceConnection: DeviceServiceTransport {
    private let transport: any DeviceServiceTransport
    private let closer: OperationCloseOnce
    init(_ transport: any DeviceServiceTransport) {
        self.transport = transport
        closer = OperationCloseOnce { transport.close() }
    }
    func sendPlist(_ value: [String: Any]) async throws {
        try Task.checkCancellation()
        try await transport.sendPlist(value)
        try Task.checkCancellation()
    }
    func receivePlist() async throws -> [String: Any] {
        try Task.checkCancellation()
        let response = try await transport.receivePlist()
        try Task.checkCancellation()
        return response
    }
    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame {
        // AFCClient has best-effort failure cleanup. Cancellation must never
        // turn that cleanup into further socket operations after interruption.
        try Task.checkCancellation()
        let response = try await transport.exchangeAFC(frame)
        try Task.checkCancellation()
        return response
    }
    func close() { closer.close() }
}
