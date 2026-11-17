import XCTest
@testable import LocSign

@MainActor
final class LocationConnectionTests: XCTestCase {
    func testReadinessSocketIsReusedForAuthenticationInsteadOfOpeningAgain() async throws {
        let transport = LocationTransportFixture()
        transport.tlsError = NSError(domain: "SyntheticTLS", code: -9807)
        var opens = 0
        let controller = DeviceLocationController(makeTransport: { host, timeout in
            XCTAssertEqual(host, "10.7.0.1")
            XCTAssertEqual(timeout, 1)
            opens += 1
            return transport
        })
        try await controller.prepareConnection(host: "10.7.0.1", timeout: 1)
        XCTAssertFalse(transport.closed)
        do {
            try await controller.set(.init(latitude: 31, longitude: 118), host: "10.7.0.1", pairingData: pairing())
            XCTFail("TLS must still be verified after readiness")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("L02"))
        }
        XCTAssertEqual(opens, 1, "Do not discard the successful connection and reopen after readiness")
        XCTAssertEqual(transport.requests, ["QueryType", "StartSession"])
        XCTAssertTrue(transport.closed)
    }

    func testHeartbeatConnectionRefusalIsDistinguishedFromControlPort() async throws {
        let transport = LocationTransportFixture()
        transport.peer = try fixture("pairing-host-cert", "der")
        let controller = DeviceLocationController(makeTransport: { _, _ in transport }, openService: { _, endpoint, _ in
            XCTAssertEqual(endpoint.port, 4567)
            throw NSError(domain: "LocSign.DeviceSocket", code: 61, userInfo: [NSLocalizedDescriptionKey: "connection refused"])
        })
        do {
            try await controller.set(.init(latitude: 31, longitude: 118), host: "10.7.0.1", pairingData: pairing())
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("L06"))
            XCTAssertTrue(error.localizedDescription.contains("4567"))
        }
        XCTAssertTrue(transport.closed)
    }

    func testChangingHostCannotReuseReadinessSocketForAnotherDevice() async throws {
        let ready = LocationTransportFixture()
        let replacement = LocationTransportFixture()
        replacement.tlsError = NSError(domain: "SyntheticTLS", code: -9807)
        var hosts: [String] = []
        let controller = DeviceLocationController(makeTransport: { host, _ in
            hosts.append(host)
            return hosts.count == 1 ? ready : replacement
        })
        try await controller.prepareConnection(host: "10.7.0.1", timeout: 1)
        do { try await controller.clear(host: "10.8.0.1", pairingData: pairing()); XCTFail() } catch { }
        XCTAssertEqual(hosts, ["10.7.0.1", "10.8.0.1"])
        XCTAssertTrue(ready.closed)
        XCTAssertTrue(ready.requests.isEmpty)
        XCTAssertTrue(replacement.closed)
    }

    func testDisconnectDuringPendingPreparationClosesLateConnection() async throws {
        let ready = expectation(description: "Connecting")
        var resume: CheckedContinuation<Void, Never>?
        let transport = LocationTransportFixture()
        let controller = DeviceLocationController(makeTransport: { _, _ in
            await withCheckedContinuation { resume = $0; ready.fulfill() }
            return transport
        })
        let task = Task { try await controller.prepareConnection(host: "10.7.0.1", timeout: 1) }
        await fulfillment(of: [ready], timeout: 3)
        await controller.disconnect()
        resume?.resume()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.closed)
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
    private func pairing() throws -> Data { try fixture("pairing-record-pem", "plist") }
}

private final class LocationTransportFixture: LocationLockdownTransport {
    var tlsError: Error?
    var peer = Data()
    var closed = false
    var requests: [String] = []
    private var replies: [[String: Any]] = [
        ["Type": "com.apple.mobile.lockdown"],
        ["SessionID": "synthetic", "EnableSessionSSL": true],
        ["Value": "synthetic-device"],
        ["Port": 4567, "EnableServiceSSL": false]
    ]
    func send(_ request: [String: Any]) async throws { requests.append(request["Request"] as? String ?? "") }
    func receive() async throws -> [String: Any] { replies.removeFirst() }
    func upgradeToTLS(using pairing: PairingRecord) async throws { if let tlsError { throw tlsError } }
    func authenticatedPeerCertificate() async throws -> Data { peer }
    func close() { closed = true }
}
