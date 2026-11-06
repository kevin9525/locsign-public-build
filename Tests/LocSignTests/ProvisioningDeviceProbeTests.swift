import XCTest
@testable import LocSign

final class ProvisioningDeviceProbeTests: XCTestCase {
    func testProbeReadsUDIDOnlyAfterTLSAndClosesSession() async throws {
        let transport = ProbeTransportFixture()
        let probe = ProvisioningDeviceProbe { host in
            XCTAssertEqual(host, "127.0.0.1")
            return transport
        }
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist")))
        let udid = try await probe.deviceUDID(host: "127.0.0.1", pairingData: data)
        XCTAssertEqual(udid, "SYNTHETIC-UDID")
        XCTAssertEqual(transport.events, ["QueryType", "StartSession", "TLS", "GetValue", "close"])
    }

    func testTLSFailureNeverReadsDeviceIdentifier() async throws {
        let transport = ProbeTransportFixture(failTLS: true)
        let probe = ProvisioningDeviceProbe { _ in transport }
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist")))
        do { _ = try await probe.deviceUDID(host: "127.0.0.1", pairingData: data); XCTFail("TLS failure accepted") }
        catch {}
        XCTAssertTrue(transport.events.contains("TLS"))
        XCTAssertFalse(transport.events.contains("GetValue"))
        XCTAssertEqual(transport.events.last, "close")
    }
}

private final class ProbeTransportFixture: LockdownTransport, @unchecked Sendable {
    var events: [String] = []
    private var responses: [[String: Any]] = [["Type": "com.apple.mobile.lockdown"],
        ["SessionID": "synthetic-session", "EnableSessionSSL": true], ["Value": "SYNTHETIC-UDID"]]
    private let failTLS: Bool
    init(failTLS: Bool = false) { self.failTLS = failTLS }
    func send(_ request: [String: Any]) async throws { events.append(request["Request"] as? String ?? "unknown") }
    func receive() async throws -> [String: Any] { responses.removeFirst() }
    func upgradeToTLS(using pairing: PairingRecord) async throws {
        events.append("TLS")
        if failTLS { throw LocSignError.install("synthetic TLS failure") }
    }
    func close() { events.append("close") }
}
