import XCTest
@testable import LocSign

final class LockdownProtocolTests: XCTestCase {
    func testStartSessionValidatesPairingAndEstablishesTLS() async throws {
        let pairingData = try Self.pairingData()
        let pairing = try PairingRecord(data: pairingData)
        let transport = FakeLockdownTransport(responses: [
            ["Type": "com.apple.mobile.lockdown"],
            ["EnableSessionSSL": true, "SessionID": "test-session"],
            ["Value": "00008020-TEST"]
        ])
        let session = LockdownSession(transport: transport, pairing: pairing)

        try await session.start()
        XCTAssertEqual(session.phase, .ready)
        let udid = try await session.queryUniqueDeviceID()
        XCTAssertEqual(udid, "00008020-TEST")
        XCTAssertEqual(transport.events, ["QueryType", "StartSession", "TLS", "GetValue"])
        XCTAssertEqual(transport.requests[1]["HostID"] as? String, pairing.hostID)
        XCTAssertEqual(transport.requests[1]["SystemBUID"] as? String, pairing.systemBUID)
        XCTAssertNil(transport.requests[1]["PairRecord"], "配对私钥记录不应以明文发给设备")
    }

    func testHandshakeStopsOnUnexpectedQueryType() async throws {
        let data = try Self.pairingData()
        let pairing = try PairingRecord(data: data)
        let transport = FakeLockdownTransport(responses: [["Type": "other"]])
        let session = LockdownSession(transport: transport, pairing: pairing)

        await assertThrows { try await session.start() }
        XCTAssertEqual(session.phase, .disconnected)
    }

    func testStartSessionRejectsUnpairedHost() async throws {
        let pairing = try PairingRecord(data: Self.pairingData())
        let transport = FakeLockdownTransport(responses: [
            ["Type": "com.apple.mobile.lockdown"],
            ["Error": "InvalidHostID"]
        ])
        let session = LockdownSession(transport: transport, pairing: pairing)

        await assertThrows { try await session.start() }

        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertEqual(transport.events, ["QueryType", "StartSession", "close"])
    }

    func testModernSessionRejectsTLSStrippingAndMissingSessionID() async throws {
        let pairing = try PairingRecord(data: Self.pairingData())
        for response: [String: Any] in [[:], ["SessionID": "test", "EnableSessionSSL": false],
                                        ["EnableSessionSSL": true]] {
            let transport = FakeLockdownTransport(responses: [["Type": "com.apple.mobile.lockdown"], response])
            let session = LockdownSession(transport: transport, pairing: pairing)
            await assertThrows { try await session.start() }
            XCTAssertEqual(session.phase, .disconnected)
            XCTAssertEqual(transport.events, ["QueryType", "StartSession", "close"])
        }
    }

    private static func pairingData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "HostID": "host-1", "SystemBUID": "buid-1",
            "HostCertificate": Data([1]), "HostPrivateKey": Data([2]),
            "RootCertificate": Data([3])
        ], format: .binary, options: 0)
    }
}

private final class FakeLockdownTransport: LockdownTransport {
    var responses: [[String: Any]]
    var events: [String] = []
    var requests: [[String: Any]] = []

    init(responses: [[String: Any]]) { self.responses = responses }

    func send(_ request: [String: Any]) async throws {
        requests.append(request)
        events.append(request["Request"] as? String ?? "unknown")
    }

    func receive() async throws -> [String: Any] {
        guard !responses.isEmpty else { throw LocSignError.install("fake response exhausted") }
        return responses.removeFirst()
    }

    func upgradeToTLS(using pairing: PairingRecord) async throws { events.append("TLS") }
    func close() { events.append("close") }
}

private extension XCTestCase {
    func assertThrows(_ expression: () async throws -> Void,
                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await expression()
            XCTFail("expected error", file: file, line: line)
        } catch { }
    }
}
