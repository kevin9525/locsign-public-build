import XCTest
@testable import LocSign

final class LocationEngineTests: XCTestCase {
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
