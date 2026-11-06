import XCTest
@testable import LocSign

@MainActor
final class ConnectionViewModelTests: XCTestCase {
    func testPairingCheckNeedsNoSigningCertificateAndInvalidatesWhenAddressChanges() async throws {
        let model = ConnectionViewModel(checkPairing: { host, data in
            XCTAssertEqual(host, "10.7.0.1")
            _ = try PairingRecord(data: data)
            return PairedDeviceProbeResult(deviceUDID: "test-device", elapsed: 0.1)
        })
        XCTAssertFalse(model.canCheckPairing)
        try model.importPairing(fixture())
        XCTAssertTrue(model.canCheckPairing)

        await model.checkPairing()
        XCTAssertEqual(model.pairedResult?.deviceUDID, "test-device")
        XCTAssertFalse(model.isChecking)

        model.host = "10.7.0.2"
        XCTAssertNil(model.pairedResult)
    }

    func testReachabilitySuccessNeverReportsPairingVerified() async {
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        })
        await model.checkReachability()
        XCTAssertTrue(model.reachable)
        XCTAssertNil(model.pairedResult)
    }

    func testFailedRecheckClearsPreviousPairingSuccess() async throws {
        var fail = false
        let model = ConnectionViewModel(checkPairing: { _, _ in
            if fail { throw LocSignError.install("配对已失效") }
            return PairedDeviceProbeResult(deviceUDID: "test-device", elapsed: 0.1)
        })
        try model.importPairing(fixture())
        await model.checkPairing()
        XCTAssertNotNil(model.pairedResult)

        fail = true
        await model.checkPairing()
        XCTAssertNil(model.pairedResult)
        XCTAssertTrue(model.message.contains("配对已失效"))
        XCTAssertFalse(model.isChecking)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record-pem", withExtension: "plist"))
    }
}
