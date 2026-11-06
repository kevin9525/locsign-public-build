import XCTest
@testable import LocSign

final class PairedDeviceProbeTests: XCTestCase {
    func testAuthenticatesAndConnectsToBothServicesWithoutInstalling() async throws {
        let transport = ProbeLockdownTransport()
        var endpoints: [LockdownServiceEndpoint] = []
        let probe = PairedDeviceProbe(makeTransport: { host in
            XCTAssertEqual(host, "10.7.0.1")
            return transport
        }, verifyService: { host, endpoint, _ in
            XCTAssertEqual(host, "10.7.0.1")
            endpoints.append(endpoint)
        })

        let result = try await probe.check(host: " 10.7.0.1 ", pairingData: fixture())

        XCTAssertEqual(result.deviceUDID, "test-device-001C")
        XCTAssertEqual(endpoints, [.init(port: 1234, enableSSL: false), .init(port: 5678, enableSSL: true)])
        XCTAssertEqual(transport.requests.compactMap { $0["Request"] as? String },
                       ["QueryType", "StartSession", "GetValue", "StartService", "StartService"])
        XCTAssertEqual(transport.requests.compactMap { $0["Service"] as? String },
                       ["com.apple.afc", "com.apple.mobile.installation_proxy"])
        XCTAssertTrue(transport.upgradedTLS)
        XCTAssertTrue(transport.closed)
    }

    func testTLSFailureDoesNotContactServicesAndClosesSession() async throws {
        let transport = ProbeLockdownTransport()
        transport.rejectTLS = true
        let probe = PairedDeviceProbe(makeTransport: { _ in transport }, verifyService: { _, _, _ in
            XCTFail("TLS 失败后不应连接服务")
        })
        do {
            _ = try await probe.check(host: "10.7.0.1", pairingData: fixture())
            XCTFail("配对认证不应成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("配对认证"))
        }
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testServiceConnectionFailureReportsStageAndClosesSession() async throws {
        let transport = ProbeLockdownTransport()
        let probe = PairedDeviceProbe(makeTransport: { _ in transport }, verifyService: { _, endpoint, _ in
            if endpoint.port == 5678 { throw LocSignError.install("连接被拒绝") }
        })
        do {
            _ = try await probe.check(host: "10.7.0.1", pairingData: fixture())
            XCTFail("安装服务不可用时不应成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("安装服务"))
        }
        XCTAssertTrue(transport.closed)
    }

    func testMalformedPairingDoesNotConnect() async throws {
        let probe = PairedDeviceProbe(makeTransport: { _ in
            XCTFail("无效配对文件不应打开网络连接")
            return ProbeLockdownTransport()
        })
        do {
            _ = try await probe.check(host: "10.7.0.1", pairingData: Data("invalid".utf8))
            XCTFail("损坏配对文件不应通过")
        } catch { }
    }

    func testOnlyLiteralDeviceAddressesAreAccepted() async throws {
        let data = try fixture()
        let probe = PairedDeviceProbe(makeTransport: { _ in
            XCTFail("无效地址不应进入 DNS 或打开连接")
            return ProbeLockdownTransport()
        })
        for host in ["", "https://example.com/", "example.com", "10.7.0.999"] {
            do {
                _ = try await probe.check(host: host, pairingData: data)
                XCTFail("无效地址不应通过：\(host)")
            } catch { }
        }
    }

    func testCancelledProbeDoesNotConnect() async throws {
        let data = try fixture()
        let probe = PairedDeviceProbe(makeTransport: { _ in
            XCTFail("取消后不应连接")
            return ProbeLockdownTransport()
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await probe.check(host: "10.7.0.1", pairingData: data)
        }
        do {
            _ = try await task.value
            XCTFail("取消后不应成功")
        } catch is CancellationError { }
        catch { XCTFail("应保留取消状态，实际为 \(error)") }
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record-pem", withExtension: "plist"))
        return try Data(contentsOf: url)
    }
}

private final class ProbeLockdownTransport: LockdownTransport {
    var requests: [[String: Any]] = []
    var responses: [[String: Any]] = [
        ["Type": "com.apple.mobile.lockdown"],
        ["SessionID": "test-session", "EnableSessionSSL": true],
        ["Value": "test-device-001C"],
        ["Port": 1234, "EnableServiceSSL": false],
        ["Port": 5678, "EnableServiceSSL": true]
    ]
    var upgradedTLS = false
    var closed = false
    var rejectTLS = false

    func send(_ request: [String: Any]) async throws { requests.append(request) }
    func receive() async throws -> [String: Any] { responses.removeFirst() }
    func upgradeToTLS(using pairing: PairingRecord) async throws {
        if rejectTLS { throw LocSignError.install("证书未通过验证") }
        upgradedTLS = true
    }
    func close() { closed = true }
}
