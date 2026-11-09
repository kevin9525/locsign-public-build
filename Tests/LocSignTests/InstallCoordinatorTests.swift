import XCTest
import Darwin
@testable import LocSign

final class InstallCoordinatorTests: XCTestCase {
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
    var failOpeningPort: UInt16?
    var failDeviceConnection = false
    init(ipa: URL, pairing: Data) { self.ipa = ipa; self.pairing = pairing }
}

private final class InstallLockdownFixture: LockdownTransport {
    var failAt: String?
    var closed = false
    private var request: [String: Any] = [:]
    func send(_ request: [String: Any]) async throws { self.request = request }
    func receive() async throws -> [String: Any] {
        let operation = request["Service"] as? String ?? request["Request"] as? String ?? ""
        if operation == failAt { throw installTLSFailure() }
        switch operation {
        case "QueryType": return ["Type": "com.apple.mobile.lockdown"]
        case "StartSession": return ["SessionID": "synthetic", "EnableSessionSSL": true]
        case "GetValue": return ["Value": "SYNTHETIC-UDID"]
        case "com.apple.afc": return ["Port": 1234, "EnableServiceSSL": false]
        case "com.apple.mobile.installation_proxy": return ["Port": 5678, "EnableServiceSSL": true]
        default: throw LocSignError.install("Unexpected test request")
        }
    }
    func upgradeToTLS(using pairing: PairingRecord) async throws {
        if failAt == "TLS" { throw installTLSFailure() }
    }
    func close() { closed = true }
}

private final class InstallServiceFixture: DeviceServiceTransport {
    var failOperation: AFCOperation?
    var failReceive = false
    var failSend = false
    var cancelWrite = false
    var closed = false
    var frames: [AFCFrame] = []
    var requests: [[String: Any]] = []
    var responseCount = 0
    func sendPlist(_ value: [String: Any]) async throws {
        requests.append(value)
        if failSend { throw installTLSFailure() }
    }
    func receivePlist() async throws -> [String: Any] {
        if failReceive { throw installTLSFailure() }
        responseCount += 1
        return responseCount == 1 ? ["Status": "Installing", "PercentComplete": 100] : ["Status": "Complete"]
    }
    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame {
        frames.append(frame)
        if frame.operation == failOperation { throw installTLSFailure() }
        if cancelWrite && frame.operation == .write { throw CancellationError() }
        if frame.operation == .fileOpen {
            return AFCFrame(operation: .fileOpenResult, packetNumber: frame.packetNumber,
                payload: Data([1, 0, 0, 0, 0, 0, 0, 0]), thisLength: nil)
        }
        return AFCFrame(operation: .status, packetNumber: frame.packetNumber,
            payload: Data(repeating: 0, count: 8), thisLength: nil)
    }
    func close() { closed = true }
}
