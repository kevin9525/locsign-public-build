import XCTest
import Darwin
@testable import LocSign

final class InstallCoordinatorTests: XCTestCase {
    func testWirelessInstallationKeepsHeartbeatUntilCompleteAndClosesIt() async throws {
        let fixture = try setup()
        fixture.afc.requiresHeartbeat = true
        fixture.installer.beforeComplete = { [heartbeat = fixture.heartbeat] in
            XCTAssertFalse(heartbeat.closed)
            try await heartbeat.challenge()
        }
        try await run(fixture)
        XCTAssertEqual(fixture.heartbeat.poloCount, 2)
        XCTAssertTrue(fixture.heartbeat.closed)
        XCTAssertEqual(fixture.installer.requests.compactMap { $0["Command"] as? String }, ["Install"])
    }

    func testKnownBackgroundHeartbeatFailurePreventsInstall() async throws {
        let fixture = try setup()
        // The pump must latch its error before closing its failed connection.
        // Let upload finish only after that observable cleanup has occurred.
        fixture.afc.beforeWrite = { [heartbeat = fixture.heartbeat] in
            heartbeat.failPendingReceive()
            try await heartbeat.waitUntilClosed()
        }
        await expectFailure(fixture, stage: "设备保活")
        XCTAssertEqual(fixture.heartbeat.poloCount, 1)
        XCTAssertTrue(fixture.installer.requests.isEmpty)
        XCTAssertTrue(fixture.afc.closed)
        XCTAssertTrue(fixture.installer.closed)
        XCTAssertTrue(fixture.heartbeat.closed)
    }

    func testHeartbeatFailuresStopBeforeUploadingOrSubmittingInstall() async throws {
        for fault in ["start", "connect", "receive", "send"] {
            let fixture = try setup()
            switch fault {
            case "start": fixture.lockdown.failAt = "com.apple.mobile.heartbeat"
            case "connect": fixture.failOpeningPort = 3456
            case "receive": fixture.heartbeat.failReceive = true
            default: fixture.heartbeat.failSend = true
            }
            await expectFailure(fixture, stage: "设备保活")
            XCTAssertTrue(fixture.afc.frames.isEmpty)
            XCTAssertTrue(fixture.installer.requests.isEmpty)
            XCTAssertTrue(fixture.lockdown.closed)
            if fault == "receive" || fault == "send" { XCTAssertTrue(fixture.heartbeat.closed) }
        }
    }

    func testInvalidHeartbeatChallengeNeverSubmitsInstall() async throws {
        let fixture = try setup()
        fixture.heartbeat.command = "Unexpected"
        do { try await run(fixture); XCTFail("Invalid heartbeat accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("设备保活")) }
        XCTAssertEqual(fixture.heartbeat.poloCount, 0)
        XCTAssertTrue(fixture.afc.frames.isEmpty)
        XCTAssertTrue(fixture.installer.requests.isEmpty)
        XCTAssertTrue(fixture.heartbeat.closed)
    }

    func testCancellationWhileWaitingForFirstHeartbeatClosesAndStopsInstallation() async throws {
        let fixture = try setup()
        fixture.heartbeat.holdFirst = true
        let waiting = expectation(description: "waiting for initial Marco")
        let finished = expectation(description: "cancelled install finished")
        fixture.heartbeat.onWaiting = { waiting.fulfill() }
        let installing = Task {
            do { try await run(fixture); XCTFail("Cancelled install succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        installing.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(fixture.heartbeat.closed)
        XCTAssertTrue(fixture.afc.frames.isEmpty)
        XCTAssertTrue(fixture.installer.requests.isEmpty)
        XCTAssertTrue(fixture.lockdown.closed)
        fixture.heartbeat.close()
        await installing.value
    }

    func testSocketAdaptersPreserveOriginalConstructorErrors() async throws {
        let fixture = try setup()
        let pairing = try PairingRecord(data: fixture.pairing)
        do {
            _ = try await LockdownNetworkTransport(host: "127.0.0.1", timeout: 0)
            XCTFail("Invalid timeout accepted")
        } catch {
            XCTAssertEqual((error as NSError).domain, "LocSign.DeviceSocket")
            XCTAssertEqual((error as NSError).code, Int(EINVAL))
        }
        do {
            _ = try await DeviceServiceConnection(host: "127.0.0.1",
                endpoint: .init(port: 1234, enableSSL: true), pairing: pairing, timeout: 0)
            XCTFail("Invalid timeout accepted")
        } catch {
            XCTAssertEqual((error as NSError).domain, "LocSign.DeviceSocket")
            XCTAssertEqual((error as NSError).code, Int(EINVAL))
        }
    }

    func testDeviceConnectionFailureReportsStageAndOriginalCause() async throws {
        let fixture = try setup()
        fixture.failDeviceConnection = true
        await expectFailure(fixture, stage: "连接设备")
        XCTAssertTrue(fixture.afc.frames.isEmpty)
        XCTAssertTrue(fixture.installer.requests.isEmpty)
    }

    func testSendingInstallFailureIsDistinctFromWaitingForResult() async throws {
        let fixture = try setup()
        fixture.installer.failSend = true
        await expectFailure(fixture, stage: "发送安装请求")
        XCTAssertEqual(fixture.installer.requests.count, 1)
        XCTAssertEqual(fixture.installer.responseCount, 0)
        XCTAssertTrue(fixture.afc.closed)
        XCTAssertTrue(fixture.installer.closed)
    }

    func testSessionFailuresReportTheExactStepAndDoNotUpload() async throws {
        for (operation, expected) in [("TLS", "配对认证"), ("GetValue", "读取设备标识"),
            ("com.apple.afc", "启动文件服务"), ("com.apple.mobile.installation_proxy", "启动安装服务")] {
            let fixture = try setup()
            fixture.lockdown.failAt = operation
            await expectFailure(fixture, stage: expected)
            XCTAssertTrue(fixture.afc.frames.isEmpty)
            XCTAssertTrue(fixture.installer.requests.isEmpty)
            XCTAssertTrue(fixture.lockdown.closed)
        }
    }

    func testServiceConnectionFailuresReportWhichServiceAndCloseOpenedConnections() async throws {
        for (port, expected) in [(UInt16(1234), "连接文件服务"), (UInt16(5678), "连接安装服务")] {
            let fixture = try setup()
            fixture.failOpeningPort = port
            await expectFailure(fixture, stage: expected)
            XCTAssertTrue(fixture.installer.requests.isEmpty)
            XCTAssertTrue(fixture.lockdown.closed)
            if port == 5678 { XCTAssertTrue(fixture.afc.closed) }
        }
    }

    func testUploadFailuresKeepTheOriginalCauseAndNeverSubmitInstall() async throws {
        for (operation, expected) in [(AFCOperation.makeDirectory, "准备上传目录"), (.write, "上传 IPA")] {
            let fixture = try setup()
            fixture.afc.failOperation = operation
            await expectFailure(fixture, stage: expected)
            XCTAssertTrue(fixture.installer.requests.isEmpty)
            XCTAssertTrue(fixture.afc.closed)
            XCTAssertTrue(fixture.installer.closed)
        }
    }

    func testDisconnectedInstallKeepsSignedFileAndDoesNotReplayInstall() async throws {
        let fixture = try setup()
        fixture.installer.failReceive = true
        await expectFailure(fixture, stage: "等待安装结果")
        XCTAssertEqual(fixture.installer.requests.compactMap { $0["Command"] as? String }, ["Install"])
        XCTAssertEqual(try Data(contentsOf: fixture.ipa), Data([1, 2, 3]))
        XCTAssertTrue(fixture.afc.closed)
        XCTAssertTrue(fixture.installer.closed)
        XCTAssertTrue(fixture.lockdown.closed)
    }

    func testSuccessRequiresCompleteAndClosesAllServices() async throws {
        let fixture = try setup()
        try await run(fixture)
        XCTAssertEqual(fixture.installer.responseCount, 2)
        XCTAssertEqual(fixture.installer.requests.compactMap { $0["Command"] as? String }, ["Install"])
        XCTAssertTrue(fixture.afc.frames.contains { $0.operation == .write && $0.payload.suffix(3) == Data([1, 2, 3]) })
        XCTAssertTrue(fixture.afc.closed)
        XCTAssertTrue(fixture.installer.closed)
        XCTAssertTrue(fixture.lockdown.closed)
    }

    func testCancellationDuringUploadRemainsCancellationAndClosesServices() async throws {
        let fixture = try setup()
        fixture.afc.cancelWrite = true
        do { try await run(fixture); XCTFail("Cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.installer.requests.isEmpty)
        XCTAssertTrue(fixture.afc.closed)
        XCTAssertTrue(fixture.installer.closed)
        XCTAssertTrue(fixture.lockdown.closed)
        XCTAssertTrue(fixture.heartbeat.closed)
    }

    func testCancellationInterruptsBlockedAFCResponseWithoutFurtherProtocolCommands() async throws {
        let fixture = try setup()
        fixture.afc.holdWrite = true
        let waiting = expectation(description: "waiting for AFC response")
        let finished = expectation(description: "cancelled AFC install returned")
        fixture.afc.blocked.onWaiting = { waiting.fulfill() }
        let task = Task {
            do { try await run(fixture); XCTFail("Cancelled installation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        let sent = fixture.afc.frames.count
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.afc.frames.count, sent)
        XCTAssertTrue(fixture.installer.requests.isEmpty)
        XCTAssertEqual(fixture.afc.blocked.closeCount, 1)
        XCTAssertEqual(fixture.installer.blocked.closeCount, 1)
        XCTAssertEqual(fixture.lockdown.closeCount, 1)
        XCTAssertEqual(fixture.heartbeat.closeCount, 1)
        fixture.afc.blocked.close()
        await task.value
    }

    func testCancellationInterruptsInstallResultWithoutSendingAFCCleanup() async throws {
        let fixture = try setup()
        fixture.installer.holdResult = true
        let waiting = expectation(description: "waiting for installation result")
        let finished = expectation(description: "cancelled result wait returned")
        fixture.installer.blocked.onWaiting = { waiting.fulfill() }
        let task = Task {
            do { try await run(fixture); XCTFail("Cancelled installation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        let sent = fixture.afc.frames.count
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.afc.frames.count, sent)
        XCTAssertEqual(fixture.installer.requests.compactMap { $0["Command"] as? String }, ["Install"])
        XCTAssertEqual(fixture.installer.responseCount, 1)
        XCTAssertEqual(fixture.afc.blocked.closeCount, 1)
        XCTAssertEqual(fixture.installer.blocked.closeCount, 1)
        XCTAssertEqual(fixture.lockdown.closeCount, 1)
        XCTAssertEqual(fixture.heartbeat.closeCount, 1)
        fixture.installer.blocked.close()
        await task.value
    }

    func testCancelledServiceOpenClosesLateConnectionWithoutUpload() async throws {
        let fixture = try setup()
        let gate = InstallBlockedRead()
        let opening = expectation(description: "opening installer service")
        gate.onWaiting = { opening.fulfill() }
        fixture.beforeOpening = { port in
            if port == 5678 { try? await gate.wait() }
        }
        let task = Task {
            do { try await run(fixture); XCTFail("Cancelled installation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [opening], timeout: 2)
        task.cancel()
        gate.close()
        await task.value
        XCTAssertTrue(fixture.afc.frames.isEmpty)
        XCTAssertTrue(fixture.installer.requests.isEmpty)
        XCTAssertEqual(fixture.afc.blocked.closeCount, 1)
        XCTAssertEqual(fixture.installer.blocked.closeCount, 1)
        XCTAssertEqual(fixture.lockdown.closeCount, 1)
        XCTAssertEqual(fixture.heartbeat.closeCount, 1)
    }

    private func expectFailure(_ fixture: InstallFixture, stage: String) async {
        do { try await run(fixture); XCTFail("Injected connection failure was ignored") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains(stage), "Missing stage: \(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("-9806"))
            let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(cause?.domain, "LocSign.DeviceSocket")
            XCTAssertEqual(cause?.code, -9806)
        }
    }

    private func setup() throws -> InstallFixture {
        let ipa = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data([1, 2, 3]).write(to: ipa)
        addTeardownBlock { try? FileManager.default.removeItem(at: ipa) }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record-pem", withExtension: "plist"))
        return InstallFixture(ipa: ipa, pairing: try Data(contentsOf: url))
    }

    private func run(_ fixture: InstallFixture) async throws {
        let coordinator = InstallCoordinator(makeTransport: { _ in
                if fixture.failDeviceConnection { throw installTLSFailure() }
                return fixture.lockdown
            },
            openService: { _, endpoint, _ in
                if endpoint.port == fixture.failOpeningPort { throw installTLSFailure() }
                await fixture.beforeOpening?(endpoint.port)
                if endpoint.port == 3456 { return fixture.heartbeat }
                return endpoint.port == 1234 ? fixture.afc : fixture.installer
            })
        try await coordinator.install(ipaURL: fixture.ipa, host: "127.0.0.1", pairingData: fixture.pairing)
    }
}

private func installTLSFailure() -> NSError {
    NSError(domain: "LocSign.DeviceSocket", code: -9806,
        userInfo: [NSLocalizedDescriptionKey: "TLS 接收失败（-9806）"])
}

private final class InstallFixture {
    let ipa: URL
    let pairing: Data
    let lockdown = InstallLockdownFixture()
    let afc = InstallServiceFixture()
    let installer = InstallServiceFixture()
    let heartbeat = InstallHeartbeatFixture()
    var failOpeningPort: UInt16?
    var failDeviceConnection = false
    var beforeOpening: ((UInt16) async -> Void)?
    init(ipa: URL, pairing: Data) {
        self.ipa = ipa; self.pairing = pairing
        afc.heartbeatReady = { [heartbeat] in heartbeat.poloCount > 0 && !heartbeat.closed }
    }
}

private final class InstallLockdownFixture: LockdownTransport {
    var failAt: String?
    private(set) var closeCount = 0
    var closed: Bool { closeCount > 0 }
    private var request: [String: Any] = [:]
    func send(_ request: [String: Any]) async throws { self.request = request }
    func receive() async throws -> [String: Any] {
        let operation = request["Service"] as? String ?? request["Request"] as? String ?? ""
        if operation == failAt { throw installTLSFailure() }
        switch operation {
        case "QueryType": return ["Type": "com.apple.mobile.lockdown"]
        case "StartSession": return ["SessionID": "synthetic", "EnableSessionSSL": true]
        case "GetValue": return ["Value": "SYNTHETIC-UDID"]
        case "com.apple.mobile.heartbeat": return ["Port": 3456, "EnableServiceSSL": true]
        case "com.apple.afc": return ["Port": 1234, "EnableServiceSSL": false]
        case "com.apple.mobile.installation_proxy": return ["Port": 5678, "EnableServiceSSL": true]
        default: throw LocSignError.install("Unexpected test request")
        }
    }
    func upgradeToTLS(using pairing: PairingRecord) async throws {
        if failAt == "TLS" { throw installTLSFailure() }
    }
    func close() { closeCount += 1 }
}

private final class InstallServiceFixture: DeviceServiceTransport {
    var failOperation: AFCOperation?
    var failReceive = false
    var failSend = false
    var cancelWrite = false
    let blocked = InstallBlockedRead()
    var closed: Bool { blocked.closeCount > 0 }
    var holdWrite = false
    var holdResult = false
    var frames: [AFCFrame] = []
    var requests: [[String: Any]] = []
    var responseCount = 0
    var requiresHeartbeat = false
    var heartbeatReady: () -> Bool = { true }
    var beforeWrite: (() async throws -> Void)?
    var beforeComplete: (() async throws -> Void)?
    func sendPlist(_ value: [String: Any]) async throws {
        requests.append(value)
        if failSend { throw installTLSFailure() }
    }
    func receivePlist() async throws -> [String: Any] {
        if failReceive { throw installTLSFailure() }
        responseCount += 1
        if holdResult { try await blocked.wait() }
        if responseCount > 1 { try await beforeComplete?() }
        return responseCount == 1 ? ["Status": "Installing", "PercentComplete": 100] : ["Status": "Complete"]
    }
    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame {
        frames.append(frame)
        if requiresHeartbeat && !heartbeatReady() { throw installTLSFailure() }
        if frame.operation == failOperation { throw installTLSFailure() }
        if cancelWrite && frame.operation == .write { throw CancellationError() }
        if frame.operation == .write { try await beforeWrite?() }
        if frame.operation == .write && holdWrite { try await blocked.wait() }
        if frame.operation == .fileOpen {
            return AFCFrame(operation: .fileOpenResult, packetNumber: frame.packetNumber,
                payload: Data([1, 0, 0, 0, 0, 0, 0, 0]), thisLength: nil)
        }
        return AFCFrame(operation: .status, packetNumber: frame.packetNumber,
            payload: Data(repeating: 0, count: 8), thisLength: nil)
    }
    func close() { blocked.close() }
}

private final class InstallHeartbeatFixture: DeviceServiceTransport {
    var failReceive = false
    var failSend = false
    private var failAfterFirstReply = false
    var command = "Marco"
    var holdFirst = false
    var onWaiting: (() -> Void)?
    private let lock = NSLock()
    private var replies = 0
    private var isClosed = false
    private var closes = 0
    private var first = true
    private var waiting: CheckedContinuation<[String: Any], Error>?
    private var pending: [[String: Any]] = []
    private var acknowledgements: [Int: CheckedContinuation<Void, Error>] = [:]
    private var closingWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    var poloCount: Int { lock.lock(); defer { lock.unlock() }; return replies }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }

    func sendPlist(_ value: [String: Any]) async throws {
        if failSend { throw installTLSFailure() }
        XCTAssertEqual(value["Command"] as? String, "Polo")
        recordReply()
    }

    private func recordReply() {
        lock.lock()
        replies += 1
        let acknowledgement = acknowledgements.removeValue(forKey: replies)
        lock.unlock()
        acknowledgement?.resume()
    }

    func receivePlist() async throws -> [String: Any] {
        if failReceive { throw installTLSFailure() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else if first && !holdFirst {
                first = false
                lock.unlock()
                continuation.resume(returning: ["Command": command, "Interval": 15])
            } else if failAfterFirstReply {
                lock.unlock()
                continuation.resume(throwing: installTLSFailure())
            } else if !pending.isEmpty {
                let value = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiting = continuation
                lock.unlock()
                onWaiting?()
            }
        }
    }

    func challenge() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            let target = replies + 1
            acknowledgements[target] = continuation
            let reader = waiting
            waiting = nil
            let packet: [String: Any] = ["Command": "Marco", "Interval": 15]
            if reader == nil { pending.append(packet) }
            lock.unlock()
            reader?.resume(returning: packet)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock()
                let expired = acknowledgements.removeValue(forKey: target)
                lock.unlock()
                expired?.resume(throwing: LocSignError.install("Subsequent heartbeat was not answered"))
            }
        }
    }

    func failPendingReceive() {
        lock.lock()
        failAfterFirstReply = true
        let reader = waiting
        waiting = nil
        lock.unlock()
        reader?.resume(throwing: installTLSFailure())
    }

    func waitUntilClosed() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isClosed { lock.unlock(); continuation.resume(); return }
            let id = UUID()
            closingWaiters[id] = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock()
                let expired = closingWaiters.removeValue(forKey: id)
                lock.unlock()
                expired?.resume(throwing: LocSignError.install("Failed heartbeat was not closed"))
            }
        }
    }

    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame {
        throw LocSignError.install("AFC request sent to heartbeat service")
    }

    func close() {
        lock.lock()
        closes += 1
        isClosed = true
        let continuation = waiting
        waiting = nil
        let acknowledgements = Array(acknowledgements.values)
        self.acknowledgements.removeAll()
        let closingWaiters = Array(closingWaiters.values)
        self.closingWaiters.removeAll()
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        acknowledgements.forEach { $0.resume(throwing: CancellationError()) }
        closingWaiters.forEach { $0.resume() }
    }
}

private final class InstallBlockedRead {
    var onWaiting: (() -> Void)?
    private let lock = NSLock()
    private var closes = 0
    private var waiting: CheckedContinuation<Void, Error>?
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if closes > 0 {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                waiting = continuation
                lock.unlock()
                onWaiting?()
            }
        }
    }

    func close() {
        lock.lock()
        closes += 1
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }
}
