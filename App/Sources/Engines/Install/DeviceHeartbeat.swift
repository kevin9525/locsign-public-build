import Foundation

/// One heartbeat connection owned by one installation. No reconnect or replay.
final class DeviceHeartbeat {
    private let connection: any DeviceServiceTransport
    private let state = State()
    private var pump: Task<Void, Never>?

    init(connection: any DeviceServiceTransport) { self.connection = connection }

    func start() async throws {
        let connection = self.connection
        let state = self.state
        do {
            try await withTaskCancellationHandler {
                try await Self.respond(on: connection)
            } onCancel: {
                self.connection.close()
            }
            try Task.checkCancellation()
            pump = Task {
                do {
                    while true { try await Self.respond(on: connection) }
                } catch {
                    // Latch before closing so the installation's next health
                    // check sees the original failure, not a shutdown error.
                    if !Task.isCancelled {
                        state.record(InstallationFailure.wrapping(error, at: .heartbeat))
                    }
                    connection.close()
                }
            }
        } catch {
            connection.close()
            throw InstallationFailure.wrapping(error, at: .heartbeat)
        }
    }

    func check() throws {
        try Task.checkCancellation()
        try state.check()
    }

    func stop() async {
        state.stop()
        pump?.cancel()
        connection.close()
        await pump?.value
    }

    private static func respond(on connection: any DeviceServiceTransport) async throws {
        try Task.checkCancellation()
        let response = try await connection.receivePlist()
        try Task.checkCancellation()
        guard response["Command"] as? String == "Marco" else {
            throw LocSignError.install("设备返回了无效的保活消息")
        }
        try await connection.sendPlist(["Command": "Polo"])
    }

    private final class State {
        private let lock = NSLock()
        private var stopped = false
        private var failure: Error?

        func record(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if !stopped && failure == nil { failure = error }
        }

        func check() throws {
            lock.lock(); defer { lock.unlock() }
            if let failure { throw failure }
            if stopped { throw CancellationError() }
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
        }
    }
}
