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
        }, checkPairing: { host, _, _ in
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
        }, checkPairing: { _, _, _ in
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
        }, checkPairing: { _, _, _ in
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
        }, checkPairing: { _, _, _ in
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
        }, checkPairing: { _, _, _ in
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

    func testCancellationKeepsSharedLockUntilPairingReturnsAndRejectsLateSuccess() async throws {
        let settings = try makeSettings()
        try settings.savePairing(data: Data(contentsOf: fixture()), name: "phone.plist")
        let entered = expectation(description: "pairing request entered")
        var reply: CheckedContinuation<PairedDeviceProbeResult, Never>?
        var pairingCalls = 0
        let model = ConnectionViewModel(settings: settings, checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _, _ in
            pairingCalls += 1
            return await withCheckedContinuation { continuation in
                reply = continuation
                entered.fulfill()
            }
        })
        let task = Task { await model.checkPairing() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.isChecking)
        XCTAssertNotNil(settings.operationID)
        task.cancel()
        XCTAssertNotNil(settings.operationID)
        await model.checkPairing()
        XCTAssertEqual(pairingCalls, 1)
        XCTAssertThrowsError(try settings.clearPairing())
        model.host = "10.7.0.2"
        XCTAssertEqual(settings.host, "10.7.0.1")
        reply?.resume(returning: PairedDeviceProbeResult(deviceUDID: "late-device", elapsed: 0.1))
        await task.value
        XCTAssertNil(model.pairedResult)
        XCTAssertFalse(model.isChecking)
        XCTAssertNil(settings.operationID)
    }

    func testAddressEditInvalidatesAnOutstandingStandaloneCheck() async {
        let entered = expectation(description: "reachability request entered")
        var reply: CheckedContinuation<ConnectionProbeResult, Never>?
        let model = ConnectionViewModel(checkReachability: { _ in
            await withCheckedContinuation { continuation in
                reply = continuation
                entered.fulfill()
            }
        })
        let task = Task { await model.checkReachability() }
        await fulfillment(of: [entered], timeout: 2)
        model.host = "10.7.0.2"
        reply?.resume(returning: ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1))
        await task.value
        XCTAssertFalse(model.reachable)
        XCTAssertNil(model.pairedResult)
        XCTAssertTrue(model.message.isEmpty)
    }

    func testCancelledFullCheckNeverStartsEitherProbe() async throws {
        var calls = 0
        let model = ConnectionViewModel(checkReachability: { _ in
            calls += 1
            return ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _, _ in
            calls += 1
            return PairedDeviceProbeResult(deviceUDID: "late-device", elapsed: 0.1)
        })
        try model.importPairing(fixture())
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.checkPairing()
        }
        await task.value
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.pairedResult)
        XCTAssertFalse(model.isChecking)
    }

    func testStepResultsPreserveVerifiedWorkAndSkipLaterStepsOnFailure() async throws {
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _, progress in
            await progress(.pairingFile, false)
            await progress(.pairingFile, true)
            await progress(.authentication, false)
            await progress(.authentication, true)
            await progress(.fileService, false)
            throw PairedProbeFailure(stage: .fileService, detail: "测试文件服务拒绝")
        })
        try model.importPairing(fixture())
        await model.checkPairing()
        XCTAssertEqual(model.state(for: .address), .passed)
        XCTAssertEqual(model.state(for: .reachability), .passed)
        XCTAssertEqual(model.state(for: .pairingFile), .passed)
        XCTAssertEqual(model.state(for: .authentication), .passed)
        XCTAssertEqual(model.state(for: .fileService), .failed)
        XCTAssertEqual(model.state(for: .installationService), .skipped)
        XCTAssertEqual(model.failedStep, .fileService)
        XCTAssertNil(model.pairedResult)
        XCTAssertNotNil(model.checkedAt)
    }

    func testMissingPairingMarksOnlyMissingMaterialFailed() async {
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        })
        XCTAssertTrue(model.canRunSelfCheck)
        await model.checkPairing()
        XCTAssertEqual(model.state(for: .reachability), .passed)
        XCTAssertEqual(model.state(for: .pairingFile), .failed)
        XCTAssertEqual(model.state(for: .authentication), .skipped)
        XCTAssertEqual(model.state(for: .fileService), .skipped)
        XCTAssertEqual(model.state(for: .installationService), .skipped)
        XCTAssertEqual(model.failedStep, .pairingFile)
        XCTAssertTrue(model.canRunSelfCheck)
    }

    func testCancellationAfterLastProgressDoesNotInvalidateEarlierPassedSteps() async throws {
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _, progress in
            for stage: PairedProbeStage in [.pairingFile, .authentication, .fileService, .installationService] {
                await progress(stage, false)
                await progress(stage, true)
            }
            withUnsafeCurrentTask { $0?.cancel() }
            return PairedDeviceProbeResult(deviceUDID: "late-device", elapsed: 0.1)
        })
        try model.importPairing(fixture())
        let task = Task { await model.checkPairing() }
        await task.value
        XCTAssertNil(model.pairedResult)
        XCTAssertEqual(model.state(for: .pairingFile), .passed)
        XCTAssertEqual(model.state(for: .fileService), .passed)
        XCTAssertEqual(model.state(for: .installationService), .cancelled)
        XCTAssertFalse(model.isChecking)
    }

    func testLateProgressCannotChangeCompletedOrInvalidatedResults() async throws {
        var progress: PairedProbeProgress?
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _, report in
            progress = report
            return PairedDeviceProbeResult(deviceUDID: "test-device", elapsed: 0.1)
        })
        try model.importPairing(fixture())
        await model.checkPairing()
        await progress?(.fileService, false)
        XCTAssertEqual(model.state(for: .fileService), .passed)
        model.host = "10.7.0.2"
        await progress?(.installationService, true)
        XCTAssertTrue(model.steps.isEmpty)
        XCTAssertNil(model.pairedResult)
        XCTAssertNil(model.checkedAt)
    }

    func testPairingCheckNeedsNoSigningCertificateAndInvalidatesWhenAddressChanges() async throws {
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { host, data, _ in
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
        let model = ConnectionViewModel(checkReachability: { _ in
            ConnectionProbeResult(service: "com.apple.mobile.lockdown", elapsed: 0.1)
        }, checkPairing: { _, _, _ in
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

    private func makeSettings() throws -> InstallationSettings {
        let name = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        return InstallationSettings(directory: directory, defaults: defaults)
    }
}
