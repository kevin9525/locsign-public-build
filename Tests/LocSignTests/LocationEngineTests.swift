import XCTest
@testable import LocSign

final class LocationEngineTests: XCTestCase {
    func testOldResendFailureKeepsItsHandlerWhileReplacementRemainsUsable() async throws {
        let oldResendEntered = expectation(description: "Old periodic resend entered")
        let newResendEntered = expectation(description: "Replacement periodic resend entered")
        let oldFailure = expectation(description: "Handler A receives old failure")
        let newFailure = expectation(description: "Handler B receives new failure")
        let replacementStarted = expectation(description: "Replacement request started")
        let releaseOld = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        defer { releaseOld.signal(); releaseNew.signal() }
        let recorder = LocationThreadRecorder()
        var sessionNumber = 0 // The factory only runs on the worker's fixed Thread.
        let worker = LocationSessionWorker(resendInterval: 0.05, makeSession: { _, _, _ in
            sessionNumber += 1
            let number = sessionNumber
            return ResendFailureLocationSession(recorder: recorder, number: number,
                entered: { (number == 1 ? oldResendEntered : newResendEntered).fulfill() },
                release: number == 1 ? releaseOld : releaseNew)
        })
        let first = try LocationCoordinate(latitude: 1, longitude: 2)
        let second = try LocationCoordinate(latitude: 3, longitude: 4)
        try await worker.set(first, host: "host", pairingData: Data(), ddiDirectory: nil, healthCheck: {}, onFailure: { _ in
            recorder.record("failure-A"); oldFailure.fulfill()
        })
        await fulfillment(of: [oldResendEntered], timeout: 2)
        let replacement = Task {
            replacementStarted.fulfill()
            try await worker.set(second, host: "host", pairingData: Data(), ddiDirectory: nil, healthCheck: {}, onFailure: { _ in
                recorder.record("failure-B"); newFailure.fulfill()
            })
        }
        await fulfillment(of: [replacementStarted], timeout: 2)
        releaseOld.signal()
        try await replacement.value
        await fulfillment(of: [oldFailure, newResendEntered], timeout: 2)
        let beforeNewFailure = recorder.snapshot().map(\.0)
        XCTAssertEqual(beforeNewFailure.filter { $0.hasPrefix("failure-") }, ["failure-A"])
        XCTAssertTrue(beforeNewFailure.contains("set-2-3.0"), "The replacement was accepted after the old session failed")
        XCTAssertFalse(beforeNewFailure.contains("close-2"), "Old failure must not close the replacement")
        releaseNew.signal()
        await fulfillment(of: [newFailure], timeout: 2)
        await worker.disconnect()
        XCTAssertEqual(recorder.snapshot().map(\.0).filter { $0.hasPrefix("failure-") }, ["failure-A", "failure-B"])
    }

    func testCoordinatesRejectNonfiniteAndOutOfRangeValues() throws {
        for pair in [(Double.nan, 0.0), (.infinity, 0), (0, -.infinity), (90.001, 0), (-90.001, 0), (0, 180.001), (0, -180.001)] {
            XCTAssertThrowsError(try LocationCoordinate(latitude: pair.0, longitude: pair.1))
        }
        XCTAssertEqual(try LocationCoordinate(latitude: -90, longitude: 180).longitude, 180)
        XCTAssertEqual(try LocationCoordinate(latitude: 90, longitude: -180).latitude, 90)
    }

    func testWorkerCreatesUsesAndClosesSessionOnOneNonMainThread() async throws {
        let recorder = LocationThreadRecorder()
        let worker = LocationSessionWorker(makeSession: { _, _, _ in
            recorder.record("create")
            return TestLocationSession(recorder: recorder)
        })
        try await worker.set(try LocationCoordinate(latitude: 1, longitude: 2), host: "host", pairingData: Data(), ddiDirectory: nil, healthCheck: {})
        try await worker.clear(host: "host", pairingData: Data(), ddiDirectory: nil, healthCheck: {})
        await worker.disconnect()
        let events = recorder.snapshot()
        XCTAssertEqual(events.map(\.0), ["create", "set", "clear", "close"])
        XCTAssertEqual(Set(events.map(\.1)).count, 1)
        XCTAssertTrue(events.allSatisfy { !$0.2 })
    }

    func testClearFailureIsPropagatedAndStillReleasesSession() async throws {
        let recorder = LocationThreadRecorder()
        let worker = LocationSessionWorker(makeSession: { _, _, _ in TestLocationSession(recorder: recorder, failClear: true) })
        do {
            try await worker.clear(host: "host", pairingData: Data(), ddiDirectory: nil, healthCheck: {})
            XCTFail("A rejected clear must not report successful restoration")
        } catch { }
        await worker.disconnect()
        XCTAssertEqual(recorder.snapshot().map(\.0), ["clear", "close"])
    }

    func testCancellationDoesNotCloseHandleWhileNativeCallIsActive() async throws {
        let entered = expectation(description: "Native call entered")
        let recorder = LocationThreadRecorder()
        let release = DispatchSemaphore(value: 0)
        let worker = LocationSessionWorker(makeSession: { _, _, _ in
            BlockingLocationSession(recorder: recorder, entered: { entered.fulfill() }, release: release)
        })
        let coordinate = try LocationCoordinate(latitude: 3, longitude: 4)
        let task = Task { try await worker.set(coordinate, host: "host", pairingData: Data(), ddiDirectory: nil, healthCheck: {}) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        XCTAssertFalse(recorder.snapshot().contains { $0.0 == "close" })
        release.signal()
        do { try await task.value; XCTFail("Cancelled request must not report success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recorder.snapshot().map(\.0), ["set-enter", "set-exit", "close"])
    }
}

private final class LocationThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, ObjectIdentifier, Bool)] = []
    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append((event, ObjectIdentifier(Thread.current), Thread.isMainThread))
    }
    func snapshot() -> [(String, ObjectIdentifier, Bool)] {
        lock.lock(); defer { lock.unlock() }; return events
    }
}

private final class TestLocationSession: LocationNativeSession {
    let recorder: LocationThreadRecorder
    let failClear: Bool
    init(recorder: LocationThreadRecorder, failClear: Bool = false) { self.recorder = recorder; self.failClear = failClear }
    func apply(_ coordinate: LocationCoordinate) throws { recorder.record("set") }
    func restore() throws {
        recorder.record("clear")
        if failClear { throw NSError(domain: "Test", code: 1) }
    }
    func close() { recorder.record("close") }
}

private final class BlockingLocationSession: LocationNativeSession {
    let recorder: LocationThreadRecorder
    let entered: () -> Void
    let release: DispatchSemaphore
    init(recorder: LocationThreadRecorder, entered: @escaping () -> Void, release: DispatchSemaphore) {
        self.recorder = recorder; self.entered = entered; self.release = release
    }
    func apply(_ coordinate: LocationCoordinate) throws {
        recorder.record("set-enter"); entered()
        _ = release.wait(timeout: .now() + 5)
        recorder.record("set-exit")
    }
    func restore() throws { }
    func close() { recorder.record("close") }
}

private final class ResendFailureLocationSession: LocationNativeSession {
    let recorder: LocationThreadRecorder
    let number: Int
    let entered: () -> Void
    let release: DispatchSemaphore
    private var calls = 0
    init(recorder: LocationThreadRecorder, number: Int, entered: @escaping () -> Void, release: DispatchSemaphore) {
        self.recorder = recorder; self.number = number; self.entered = entered; self.release = release
    }
    func apply(_ coordinate: LocationCoordinate) throws {
        calls += 1
        recorder.record("set-\(number)-\(coordinate.latitude)")
        if calls > 1 {
            entered()
            _ = release.wait(timeout: .now() + 5)
            throw NSError(domain: "InjectedResendFailure", code: number)
        }
    }
    func restore() throws { }
    func close() { recorder.record("close-\(number)") }
}
