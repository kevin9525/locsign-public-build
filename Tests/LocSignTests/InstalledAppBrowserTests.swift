import XCTest
@testable import LocSign

final class InstalledAppBrowserTests: XCTestCase {
    func testBrowseMergesContiguousPagesAndReturnsAuthenticatedDeviceIdentity() async throws {
        let fixture = try setup(responses: [
            page([app("com.example.first", name: "First", version: "1.2")], index: 0),
            page([["CFBundleIdentifier": "com.example.second", "CFBundleName": "Second",
                   "CFBundleVersion": "42"]], index: 1),
            ["Status": "Complete"]
        ])
        fixture.service.beforeSend = { [heartbeat = fixture.heartbeat] in
            XCTAssertEqual(heartbeat.requests.first?["Command"] as? String, "Polo")
            XCTAssertEqual(heartbeat.closeCount, 0)
        }
        let result = try await run(fixture)
        XCTAssertEqual(result.deviceUDID, "VERIFIED-DEVICE-UDID")
        XCTAssertEqual(result.apps, [
            InstalledApp(id: "com.example.first", name: "First", version: "1.2"),
            InstalledApp(id: "com.example.second", name: "Second", version: "42")
        ])
        let request = try XCTUnwrap(fixture.service.requests.first)
        XCTAssertEqual(fixture.service.requests.count, 1)
        XCTAssertEqual(request["Command"] as? String, "Browse")
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "User")
        XCTAssertEqual(Set(options["ReturnAttributes"] as? [String] ?? []), Set([
            "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
            "CFBundleShortVersionString", "CFBundleVersion", "ApplicationType"
        ]))
        XCTAssertEqual(fixture.lockdown.startedServices,
            ["com.apple.mobile.heartbeat", "com.apple.mobile.installation_proxy"])
        XCTAssertTrue(fixture.lockdown.usedTLS)
        assertClosed(fixture)
    }

    func testCompleteAloneIsAValidEmptyList() async throws {
        let fixture = try setup(responses: [["Status": "Complete"]])
        let result = try await run(fixture)
        XCTAssertTrue(result.apps.isEmpty)
        assertClosed(fixture)
    }

    func testCompleteCanCarryTheFinalPage() async throws {
        var finalPage = page([["CFBundleIdentifier": "com.example.minimal"]], index: 0)
        finalPage["Status"] = "Complete"
        let fixture = try setup(responses: [finalPage])
        let result = try await run(fixture)
        XCTAssertEqual(result.apps, [.init(id: "com.example.minimal", name: "com.example.minimal", version: "未知")])
        assertClosed(fixture)
    }

    func testUnicodeNamesAndVersionFallbackRemainDisplayable() async throws {
        let fixture = try setup(responses: [page([
            ["CFBundleIdentifier": "com.example.family", "CFBundleDisplayName": "家人 👨‍👩‍👧",
             "CFBundleShortVersionString": "", "CFBundleVersion": "12"]
        ], index: 0), ["Status": "Complete"]])
        let result = try await run(fixture)
        XCTAssertEqual(result.apps.first, InstalledApp(id: "com.example.family", name: "家人 👨‍👩‍👧", version: "12"))
        assertClosed(fixture)
    }

    func testMalformedRowsNeverReturnAPartialList() async throws {
        let malformed: [[String: Any]] = [
            ["CFBundleDisplayName": "Missing identifier"],
            ["CFBundleIdentifier": ""],
            ["CFBundleIdentifier": "  "],
            ["CFBundleIdentifier": 123],
            ["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": 123],
            ["CFBundleIdentifier": "com.example.app", "CFBundleVersion": ["1"]],
            ["CFBundleIdentifier": "com.example.app", "ApplicationType": "System"],
            ["CFBundleIdentifier": "com.example.app", "CFBundleName": String(repeating: "x", count: 2048)]
        ]
        for row in malformed {
            let fixture = try setup(responses: [page([app("com.example.valid")], index: 0),
                page([row], index: 1), ["Status": "Complete"]])
            await expectFailure(fixture)
            assertClosed(fixture)
        }
    }

    func testMalformedPageCountersAndStatusesAreRejected() async throws {
        let malformed: [[String: Any]] = [
            ["Status": "BrowsingApplications", "CurrentList": "wrong", "CurrentIndex": 0, "CurrentAmount": 1],
            ["Status": "BrowsingApplications", "CurrentList": ["wrong"], "CurrentIndex": 0, "CurrentAmount": 1],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentIndex": -1, "CurrentAmount": 0],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentIndex": true, "CurrentAmount": 0],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentIndex": 0.5, "CurrentAmount": 0],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentIndex": "0", "CurrentAmount": 0],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentIndex": 0, "CurrentAmount": 1],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentIndex": 0, "CurrentAmount": false],
            ["Status": "BrowsingApplications", "CurrentList": [], "CurrentAmount": 0],
            ["Status": "BrowsingApplications"],
            ["Status": "Complete", "CurrentIndex": 0, "CurrentAmount": 0],
            ["Status": "Installing"],
            [:]
        ]
        for response in malformed {
            let fixture = try setup(responses: [response, ["Status": "Complete"]])
            await expectFailure(fixture)
            assertClosed(fixture)
        }
    }

    func testSkippedAndReplayedPageIndexesAreRejected() async throws {
        for secondIndex in [0, 2] {
            let fixture = try setup(responses: [page([app("com.example.one")], index: 0),
                page([app("com.example.two")], index: secondIndex), ["Status": "Complete"]])
            await expectFailure(fixture)
            assertClosed(fixture)
        }
    }

    func testRepeatedBundleIdentifiersAreRejectedEvenWithMatchingMetadata() async throws {
        for secondName in ["First", "Conflicting"] {
            let fixture = try setup(responses: [page([app("com.example.one", name: "First")], index: 0),
                page([app("com.example.one", name: secondName)], index: 1), ["Status": "Complete"]])
            await expectFailure(fixture)
            assertClosed(fixture)
        }
    }

    func testServiceErrorWinsOverComplete() async throws {
        for error in ["PermissionDenied" as Any, 17] {
            let fixture = try setup(responses: [["Status": "Complete", "Error": error]])
            await expectFailure(fixture)
            assertClosed(fixture)
        }
    }

    func testMissingCompleteIsAFailure() async throws {
        let fixture = try setup(responses: [page([app("com.example.one")], index: 0)])
        await expectFailure(fixture)
        assertClosed(fixture)
    }

    func testTotalRowsAreBoundedAcrossPages() async throws {
        let rows = (0..<6000).map { app("com.example.app\($0)") }
        let moreRows = (6000..<12000).map { app("com.example.app\($0)") }
        let fixture = try setup(responses: [page(rows, index: 0), page(moreRows, index: 6000), ["Status": "Complete"]])
        await expectFailure(fixture)
        assertClosed(fixture)
    }

    func testRowLimitAcceptsExactlyTenThousandApps() async throws {
        let rows = (0..<5000).map { ["CFBundleIdentifier": "com.example.app\($0)"] }
        let moreRows = (5000..<10000).map { ["CFBundleIdentifier": "com.example.app\($0)"] }
        let fixture = try setup(responses: [page(rows, index: 0), page(moreRows, index: 5000), ["Status": "Complete"]])
        let result = try await run(fixture)
        XCTAssertEqual(result.apps.count, 10000)
        XCTAssertEqual(result.apps.last?.id, "com.example.app9999")
        assertClosed(fixture)
    }

    func testUnendingEmptyPagesAreBounded() async throws {
        let fixture = try setup(responses: [])
        fixture.service.repeatedResponse = page([], index: 0)
        await expectFailure(fixture)
        XCTAssertLessThanOrEqual(fixture.service.responseCount, 1024)
        assertClosed(fixture)
    }

    func testDeviceIdentityMustBeReadBeforeAnyServiceIsStarted() async throws {
        let fixture = try setup(responses: [["Status": "Complete"]])
        fixture.lockdown.deviceUDID = ""
        await expectFailure(fixture)
        XCTAssertTrue(fixture.lockdown.startedServices.isEmpty)
        XCTAssertTrue(fixture.service.requests.isEmpty)
        XCTAssertEqual(fixture.lockdown.closeCount, 1)
    }

    func testInvalidInitialHeartbeatPreventsBrowse() async throws {
        let fixture = try setup(responses: [["Status": "Complete"]], heartbeat: [["Command": "Invalid"]])
        await expectFailure(fixture)
        XCTAssertTrue(fixture.service.requests.isEmpty)
        XCTAssertEqual(fixture.heartbeat.closeCount, 1)
        XCTAssertEqual(fixture.lockdown.closeCount, 1)
    }

    func testLatchedHeartbeatFailureCannotReturnACompletedList() async throws {
        let fixture = try setup(responses: [["Status": "Complete"]])
        let heartbeatClosed = expectation(description: "failed heartbeat closed")
        fixture.heartbeat.onClose = { heartbeatClosed.fulfill() }
        fixture.service.beforeReceive = { [self] in
            fixture.heartbeat.failReceive(browseFixtureFailure())
            await fulfillment(of: [heartbeatClosed], timeout: 2)
        }
        await expectFailure(fixture)
        assertClosed(fixture)
    }

    func testServiceOpenFailuresClosePreviouslyOpenedResources() async throws {
        for port in [UInt16(3456), UInt16(5678)] {
            let fixture = try setup(responses: [["Status": "Complete"]])
            fixture.failOpeningPort = port
            await expectFailure(fixture)
            XCTAssertEqual(fixture.lockdown.closeCount, 1)
            if port == 5678 { XCTAssertEqual(fixture.heartbeat.closeCount, 1) }
        }
    }

    func testCancellationInterruptsAnOutstandingBrowseRead() async throws {
        let fixture = try setup(responses: [])
        fixture.service.waitOnExhaustion = true
        let waiting = expectation(description: "waiting for browse page")
        let finished = expectation(description: "cancelled browse returned")
        fixture.service.onWaiting = { waiting.fulfill() }
        let task = Task { [self] in
            do { _ = try await run(fixture); XCTFail("Cancelled browse succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        assertClosed(fixture)
        fixture.service.close()
        await task.value
    }

    func testCancellationInterruptsAnOutstandingIdentityRead() async throws {
        let fixture = try setup(responses: [["Status": "Complete"]])
        fixture.lockdown.holdIdentity = true
        let waiting = expectation(description: "waiting for device identity")
        let finished = expectation(description: "cancelled session returned")
        fixture.lockdown.onWaiting = { waiting.fulfill() }
        let task = Task { [self] in
            do { _ = try await run(fixture); XCTFail("Cancelled browse succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.lockdown.closeCount, 1)
        XCTAssertTrue(fixture.lockdown.startedServices.isEmpty)
        fixture.lockdown.close()
        await task.value
    }

    func testCancellationWhileConnectingClosesTheLateOpenedService() async throws {
        let fixture = try setup(responses: [["Status": "Complete"]])
        let gate = BrowseServiceFixture([])
        gate.waitOnExhaustion = true
        let opening = expectation(description: "opening installation proxy")
        gate.onWaiting = { opening.fulfill() }
        let browser = InstalledAppBrowser(makeTransport: { _ in fixture.lockdown }, openService: { _, endpoint, _ in
            if endpoint.port == 3456 { return fixture.heartbeat }
            // An underlying connect can finish after cancellation. Return the
            // acquired service anyway to exercise the browser's ownership path.
            _ = try? await gate.receivePlist()
            return fixture.service
        })
        let task = Task {
            do {
                _ = try await browser.listApps(host: "127.0.0.1", pairingData: fixture.pairing)
                XCTFail("Cancelled browse succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [opening], timeout: 2)
        task.cancel()
        gate.close()
        await task.value
        XCTAssertTrue(fixture.service.requests.isEmpty)
        assertClosed(fixture)
    }

    private func app(_ id: String, name: String = "App", version: String = "1") -> [String: Any] {
        ["CFBundleIdentifier": id, "CFBundleDisplayName": name,
         "CFBundleShortVersionString": version, "ApplicationType": "User"]
    }

    private func page(_ rows: [[String: Any]], index: Int) -> [String: Any] {
        ["Status": "BrowsingApplications", "CurrentList": rows,
         "CurrentIndex": index, "CurrentAmount": rows.count]
    }

    private func setup(responses: [[String: Any]],
                       heartbeat: [[String: Any]] = [["Command": "Marco", "Interval": 15]]) throws -> BrowseFixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record-pem", withExtension: "plist"))
        return BrowseFixture(pairing: try Data(contentsOf: url), responses: responses, heartbeat: heartbeat)
    }

    private func run(_ fixture: BrowseFixture) async throws -> InstalledAppList {
        let browser = InstalledAppBrowser(makeTransport: { _ in fixture.lockdown }, openService: { _, endpoint, _ in
            if endpoint.port == fixture.failOpeningPort { throw browseFixtureFailure() }
            switch endpoint.port {
            case 3456: return fixture.heartbeat
            case 5678: return fixture.service
            default: throw browseFixtureFailure()
            }
        })
        return try await browser.listApps(host: "127.0.0.1", pairingData: fixture.pairing)
    }

    private func expectFailure(_ fixture: BrowseFixture, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await run(fixture); XCTFail("Invalid or interrupted browse succeeded", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }

    private func assertClosed(_ fixture: BrowseFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.lockdown.closeCount, 1, file: file, line: line)
        XCTAssertEqual(fixture.heartbeat.closeCount, 1, file: file, line: line)
        XCTAssertEqual(fixture.service.closeCount, 1, file: file, line: line)
    }
}

private func browseFixtureFailure() -> NSError {
    NSError(domain: "InstalledAppBrowserTests.Transport", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Synthetic transport disconnected"])
}

private final class BrowseFixture {
    let pairing: Data
    let lockdown = BrowseLockdownFixture()
    let service: BrowseServiceFixture
    let heartbeat: BrowseServiceFixture
    var failOpeningPort: UInt16?

    init(pairing: Data, responses: [[String: Any]], heartbeat: [[String: Any]]) {
        self.pairing = pairing
        self.service = BrowseServiceFixture(responses)
        self.heartbeat = BrowseServiceFixture(heartbeat)
        self.heartbeat.waitOnExhaustion = true
    }
}

private final class BrowseLockdownFixture: LockdownTransport {
    var deviceUDID = "VERIFIED-DEVICE-UDID"
    var holdIdentity = false
    var onWaiting: (() -> Void)?
    private(set) var usedTLS = false
    private(set) var startedServices: [String] = []
    private let held = BrowseServiceFixture([])
    private var request: [String: Any] = [:]
    var closeCount: Int { held.closeCount }

    init() { held.waitOnExhaustion = true }

    func send(_ request: [String: Any]) async throws {
        self.request = request
        if let service = request["Service"] as? String { startedServices.append(service) }
    }

    func receive() async throws -> [String: Any] {
        let operation = request["Service"] as? String ?? request["Request"] as? String ?? ""
        switch operation {
        case "QueryType": return ["Type": "com.apple.mobile.lockdown"]
        case "StartSession": return ["SessionID": "test-session", "EnableSessionSSL": true]
        case "GetValue":
            XCTAssertTrue(usedTLS)
            XCTAssertEqual(request["Key"] as? String, "UniqueDeviceID")
            if holdIdentity {
                held.onWaiting = onWaiting
                return try await held.receivePlist()
            }
            return ["Value": deviceUDID]
        case "com.apple.mobile.heartbeat": return ["Port": 3456, "EnableServiceSSL": true]
        case "com.apple.mobile.installation_proxy": return ["Port": 5678, "EnableServiceSSL": true]
        default: throw browseFixtureFailure()
        }
    }

    func upgradeToTLS(using pairing: PairingRecord) async throws { usedTLS = true }
    func close() { held.close() }
}

private final class BrowseServiceFixture: DeviceServiceTransport {
    var waitOnExhaustion = false
    var repeatedResponse: [String: Any]?
    var onWaiting: (() -> Void)?
    var onClose: (() -> Void)?
    var beforeSend: (() -> Void)?
    var beforeReceive: (() async -> Void)?
    private let lock = NSLock()
    private var responses: [[String: Any]]
    private var sent: [[String: Any]] = []
    private var closes = 0
    private var received = 0
    private var receiveFailure: Error?
    private var waiter: CheckedContinuation<[String: Any], Error>?

    init(_ responses: [[String: Any]]) { self.responses = responses }
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    var responseCount: Int { lock.lock(); defer { lock.unlock() }; return received }

    func sendPlist(_ value: [String: Any]) async throws {
        beforeSend?()
        record(value)
    }

    private func record(_ value: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        sent.append(value)
    }

    func receivePlist() async throws -> [String: Any] {
        await beforeReceive?()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closes > 0 {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else if let receiveFailure {
                lock.unlock()
                continuation.resume(throwing: receiveFailure)
            } else if !responses.isEmpty {
                received += 1
                let response = responses.removeFirst()
                lock.unlock()
                continuation.resume(returning: response)
            } else if let repeatedResponse {
                received += 1
                lock.unlock()
                continuation.resume(returning: repeatedResponse)
            } else if waitOnExhaustion {
                waiter = continuation
                lock.unlock()
                onWaiting?()
            } else {
                lock.unlock()
                continuation.resume(throwing: browseFixtureFailure())
            }
        }
    }

    func failReceive(_ error: Error) {
        lock.lock()
        receiveFailure = error
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame {
        XCTFail("Read-only browser must not send AFC operations")
        throw browseFixtureFailure()
    }

    func close() {
        lock.lock()
        closes += 1
        let firstClose = closes == 1
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
        if firstClose { onClose?() }
    }
}
