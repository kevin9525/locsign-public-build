import Foundation

protocol LocationNativeSession: AnyObject {
    func apply(_ coordinate: LocationCoordinate) throws
    func restore() throws
    func close()
}

private final class NativeLocationSession: LocationNativeSession {
    private let native: LSDeviceLocationSession
    init(host: String, pairingData: Data, ddiDirectory: URL?) throws {
        native = try LSDeviceLocationSession(host: host, pairingData: pairingData, ddiDirectory: ddiDirectory)
    }
    func apply(_ coordinate: LocationCoordinate) throws { try native.applyLatitude(coordinate.latitude, longitude: coordinate.longitude) }
    func restore() throws { try native.restore() }
    func close() { native.close() }
}

/// A serial queue is insufficient: Rust's tunnel handles require one physical thread.
final class LocationSessionWorker: @unchecked Sendable {
    typealias Factory = (String, Data, URL?) throws -> any LocationNativeSession
    private let state: State

    init(resendInterval: TimeInterval = 5,
         makeSession: @escaping Factory = { try NativeLocationSession(host: $0, pairingData: $1, ddiDirectory: $2) }) {
        precondition(resendInterval.isFinite && resendInterval > 0)
        let state = State(resendInterval: resendInterval, makeSession: makeSession)
        self.state = state
        let thread = Thread { state.run() }
        thread.name = "com.locsign.location-session"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { state.shutdown() }

    func set(_ coordinate: LocationCoordinate, host: String, pairingData: Data, ddiDirectory: URL?,
             healthCheck: @escaping () throws -> Void,
             onFailure: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await perform { state, checkCancellation in
            try healthCheck()
            if state.session == nil { state.session = try state.makeSession(host, pairingData, ddiDirectory) }
            try checkCancellation()
            try state.session?.apply(coordinate)
            state.coordinate = coordinate
            state.healthCheck = healthCheck
            // Install with the accepted coordinate on the owning Thread. A
            // resend already in flight retains its previous request's handler.
            state.failureHandler = onFailure
            state.nextResend = Date().addingTimeInterval(state.resendInterval)
        }
    }

    func clear(host: String, pairingData: Data, ddiDirectory: URL?, healthCheck: @escaping () throws -> Void) async throws {
        try await perform { state, checkCancellation in
            defer { state.close() }
            try healthCheck()
            if state.session == nil { state.session = try state.makeSession(host, pairingData, ddiDirectory) }
            try checkCancellation()
            try state.session?.restore()
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            state.enqueue { state in state.close(); continuation.resume() }
        }
    }

    private func perform(_ action: @escaping (State, () throws -> Void) throws -> Void) async throws {
        let cancellation = CancellationFlag()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.enqueue { state in
                    do {
                        try cancellation.check()
                        try action(state, cancellation.check)
                        try cancellation.check()
                        continuation.resume()
                    } catch {
                        state.close()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class CancellationFlag: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [(State) -> Void] = []
        var stopping = false
        var failureHandler: (@Sendable (String) -> Void)?
        let makeSession: Factory
        let resendInterval: TimeInterval
        // Below this line, state is exclusively accessed on the worker Thread.
        var session: (any LocationNativeSession)?
        var coordinate: LocationCoordinate?
        var healthCheck: (() throws -> Void)?
        var nextResend = Date.distantFuture

        init(resendInterval: TimeInterval, makeSession: @escaping Factory) {
            self.resendInterval = resendInterval; self.makeSession = makeSession
        }
        func enqueue(_ job: @escaping (State) -> Void) {
            condition.lock(); jobs.append(job); condition.signal(); condition.unlock()
        }
        func shutdown() { condition.lock(); stopping = true; condition.signal(); condition.unlock() }
        func close() {
            session?.close()
            session = nil
            coordinate = nil
            healthCheck = nil
            failureHandler = nil
            nextResend = .distantFuture
        }
        func run() {
            while true {
                condition.lock()
                while jobs.isEmpty && !stopping && Date() < nextResend { _ = condition.wait(until: nextResend) }
                if !jobs.isEmpty {
                    let job = jobs.removeFirst()
                    condition.unlock()
                    autoreleasepool { job(self) }
                    continue
                }
                if stopping { condition.unlock(); close(); return }
                let handler = failureHandler
                condition.unlock()
                autoreleasepool {
                    do {
                        try healthCheck?()
                        if let coordinate { try session?.apply(coordinate) }
                        nextResend = Date().addingTimeInterval(resendInterval)
                    } catch {
                        close()
                        handler?("定位连接已中断，当前设备位置未确认。\(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
