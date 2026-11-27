import XCTest
@testable import LocSign

@MainActor
final class ConnectionViewModelTests: XCTestCase {
    // These exercise the existing entry point so the baseline fails on behavior,
    // rather than failing to compile because a new API is absent.
    func testFullCheckVerifiesReachabilityBeforePairing() async throws {
        var calls: [String] = []
        let model = ConnectionViewModel(checkReachability: { host in
            XCTAssertEqual(host, "10.7.0.1")
            calls.append("reachability")
            return ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { host, _ in
            XCTAssertEqual(host, "10.7.0.1")
            calls.append("pairing")
            return PairedDeviceProbeResult(deviceUDID: "test-device", elapsed: 0.2)
        })
        try model.importPairing(fixture())
        await model.checkPairing()
        XCTAssertEqual(calls, ["reachability", "pairing"])
        XCTAssertTrue(model.reachable)
        XCTAssertEqual(model.pairedResult?.deviceUDID, "test-device")
    }

    func testUnreachableDeviceStopsBeforePairingAndNeverClaimsSuccess() async throws {
        var pairingAttempts = 0
        let model = ConnectionViewModel(checkReachability: { _ in
            throw LocSignError.install("测试连接超时")
        }, checkPairing: { _, _ in
            pairingAttempts += 1
            return PairedDeviceProbeResult(deviceUDID: "test-device", elapsed: 0.1)
        })
        try model.importPairing(fixture())
        await model.checkPairing()
        XCTAssertEqual(pairingAttempts, 0)
        XCTAssertFalse(model.reachable)
        XCTAssertNil(model.pairedResult)
        XCTAssertTrue(model.message.contains("测试连接超时"))
        XCTAssertFalse(model.isChecking)
    }

    func testMissingPairingStillChecksDeviceAndExplainsNextStep() async {
        var checks = 0
        let model = ConnectionViewModel(checkReachability: { _ in
            checks += 1
            return ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _ in
            XCTFail("Missing pairing must not start authentication")
            throw CancellationError()
        })
        await model.checkPairing()
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(model.reachable)
        XCTAssertNil(model.pairedResult)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertFalse(model.isChecking)
    }

    func testInvalidAddressDoesNotStartEitherNetworkCheck() async throws {
        var attempts = 0
        let model = ConnectionViewModel(checkReachability: { _ in
            attempts += 1
            return ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _ in
            attempts += 1
            return PairedDeviceProbeResult(deviceUDID: "test-device", elapsed: 0.1)
        })
        try model.importPairing(fixture())
        for address in ["", "https://example.com/", "example.com", "10.7.0.999"] {
            model.host = address
            await model.checkPairing()
            XCTAssertEqual(attempts, 0)
            XCTAssertNil(model.pairedResult)
            XCTAssertFalse(model.message.isEmpty)
        }
    }

    func testCheckFailureRedactsSensitiveDetails() async throws {
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _ in
            throw LocSignError.install("hostprivatekey=synthetic-private-value")
        })
        try model.importPairing(fixture())
        await model.checkPairing()
        XCTAssertFalse(model.message.contains("synthetic-private-value"))
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertNil(model.pairedResult)
    }

    func testCancelledReachabilityDoesNotStartNetworkWork() async {
        var attempts = 0
        let model = ConnectionViewModel(checkReachability: { _ in
            attempts += 1
            return ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.checkReachability()
        }
        await task.value
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(model.reachable)
        XCTAssertFalse(model.isChecking)
    }

    func testImportFailureRedactsSensitiveDetails() {
        let model = ConnectionViewModel()
        model.reportImportError(LocSignError.install("password=synthetic-password"))
        XCTAssertFalse(model.message.contains("synthetic-password"))
        XCTAssertFalse(model.message.isEmpty)
    }

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
