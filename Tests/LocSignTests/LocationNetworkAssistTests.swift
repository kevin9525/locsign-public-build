import XCTest
@testable import LocSign

@MainActor
final class LocationNetworkAssistTests: XCTestCase {
    // Device access must wait for a real QueryType response after the shortcut callback.
    func testWaitsForEndpointAndRestoresDataAfterDeviceOperation() async throws {
        let fixture = makeFixture()
        var events: [String] = []
        var attempts = 0
        let assist = LocationNetworkAssist(defaults: fixture, runShortcut: { action in
            events.append(action.rawValue)
        }, probe: { host, _ in
            XCTAssertEqual(host, "10.7.0.1")
            attempts += 1
            events.append("probe")
            if attempts < 3 { throw URLError(.cannotConnectToHost) }
        }, pause: { }, now: { 0 })
        try await assist.run(host: "10.7.0.1") { events.append("device") }
        XCTAssertEqual(events, ["disable", "probe", "probe", "probe", "device", "enable"])
        XCTAssertFalse(assist.requiresRestore)
    }

    func testUnreachableEndpointNeverAppliesLocationAndStillRestoresData() async {
        var time: TimeInterval = 0
        var actions: [LocationNetworkAssist.Action] = []
        let assist = LocationNetworkAssist(defaults: makeFixture(), runShortcut: { actions.append($0) },
            probe: { _, _ in throw URLError(.cannotConnectToHost) },
            pause: { time += 1 }, now: { time }, readinessTimeout: 2)
        do {
            try await assist.run(host: "10.7.0.1") { XCTFail("Unreachable endpoint must not receive location") }
            XCTFail("Expected readiness timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("设备服务")) }
        XCTAssertEqual(actions, [.disable, .enable])
        XCTAssertFalse(assist.requiresRestore)
    }

    func testDeviceFailureIsPreservedWhenRestoreAlsoFailsAndSurvivesRelaunch() async {
        let defaults = makeFixture()
        let assist = LocationNetworkAssist(defaults: defaults, runShortcut: { action in
            if action == .enable { throw URLError(.timedOut) }
        }, probe: { _, _ in })
        do {
            try await assist.run(host: "10.7.0.1") { throw URLError(.secureConnectionFailed) }
            XCTFail("Expected device error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .secureConnectionFailed) }
        XCTAssertTrue(assist.requiresRestore)
        let reopened = LocationNetworkAssist(defaults: defaults, runShortcut: { _ in }, probe: { _, _ in })
        XCTAssertTrue(reopened.requiresRestore)
        await reopened.restoreData()
        XCTAssertFalse(reopened.requiresRestore)
    }

    func testFailedRestoreDoesNotTurnAcceptedDeviceOperationIntoFailure() async throws {
        let assist = LocationNetworkAssist(defaults: makeFixture(), runShortcut: { action in
            if action == .enable { throw URLError(.timedOut) }
        }, probe: { _, _ in })
        var applied = false
        try await assist.run(host: "10.7.0.1") { applied = true }
        XCTAssertTrue(applied)
        XCTAssertTrue(assist.requiresRestore)
        XCTAssertNotNil(assist.restoreWarning)
    }

    func testCancellationAfterDataIsDisabledRestoresOutsideCancelledTask() async {
        var actions: [LocationNetworkAssist.Action] = []
        let entered = expectation(description: "Data disabled")
        var release: CheckedContinuation<Void, Never>?
        let assist = LocationNetworkAssist(defaults: makeFixture(), runShortcut: { action in
            actions.append(action)
            if action == .disable {
                await withCheckedContinuation { release = $0; entered.fulfill() }
            } else { XCTAssertFalse(Task.isCancelled) }
        }, probe: { _, _ in XCTFail("Cancelled operation must not probe") })
        let task = Task { try await assist.run(host: "10.7.0.1") { XCTFail("Must not apply after cancellation") } }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        release?.resume()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(actions, [.disable, .enable])
        XCTAssertFalse(assist.requiresRestore)
    }

    func testPreviouslyUnconfirmedRestoreBlocksAnotherDisable() async {
        let defaults = makeFixture()
        defaults.set(true, forKey: "location.networkAssist.requiresRestore")
        let assist = LocationNetworkAssist(defaults: defaults,
            runShortcut: { _ in XCTFail("Restore first") }, probe: { _, _ in XCTFail() })
        do { try await assist.run(host: "10.7.0.1") { XCTFail() }; XCTFail() } catch { }
        XCTAssertTrue(assist.requiresRestore)
    }

    func testUnconfirmedDisableNeverRacesAnAutomaticEnable() async {
        var actions: [LocationNetworkAssist.Action] = []
        let assist = LocationNetworkAssist(defaults: makeFixture(), runShortcut: { action in
            actions.append(action)
            throw LocationShortcutRunner.Failure.completionUnknown
        }, probe: { _, _ in XCTFail() })
        do { try await assist.run(host: "10.7.0.1") { XCTFail() }; XCTFail() } catch { }
        XCTAssertEqual(actions, [.disable])
        XCTAssertTrue(assist.requiresRestore)
        XCTAssertNotNil(assist.restoreWarning)
    }

    private func makeFixture() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

@MainActor
final class LocationShortcutRunnerTests: XCTestCase {
    func testTimedOutShortcutRejectsLateCallbackInsteadOfClaimingCompletion() async throws {
        let launched = expectation(description: "Shortcut launched")
        let timerStarted = expectation(description: "Timer installed")
        var request: URL?
        var expire: CheckedContinuation<Void, Never>?
        let runner = LocationShortcutRunner(openURL: { request = $0; launched.fulfill(); return true },
            waitForTimeout: { await withCheckedContinuation { expire = $0; timerStarted.fulfill() } })
        let task = Task { try await runner.run(.disable) }
        await fulfillment(of: [launched, timerStarted], timeout: 2)
        expire?.resume()
        do { try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is LocationShortcutRunner.Failure) }
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request), resolvingAgainstBaseURL: false)?.queryItems)
        let late = try XCTUnwrap(URL(string: XCTUnwrap(query.first(where: { $0.name == "x-success" })?.value)))
        XCTAssertFalse(runner.handle(late))
    }

    func testURLLaunchAcknowledgementDoesNotCompleteShortcutAndRejectsStaleCallback() async throws {
        let launched = expectation(description: "Launched shortcut")
        var request: URL?
        let runner = LocationShortcutRunner(openURL: { request = $0; launched.fulfill(); return true })
        var completed = false
        let task = Task { try await runner.run(.disable); completed = true }
        await fulfillment(of: [launched], timeout: 2)
        XCTAssertFalse(completed)
        XCTAssertFalse(runner.handle(URL(string: "locsign://network-assist/invalid?result=success")!))
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "name" })?.value, "LocSign关闭蜂窝数据")
        let callback = try XCTUnwrap(URL(string: XCTUnwrap(query.first(where: { $0.name == "x-success" })?.value) + "?result=shortcut-output"))
        XCTAssertTrue(runner.handle(callback))
        try await task.value
        XCTAssertTrue(completed)
        XCTAssertFalse(runner.handle(callback))
    }

    func testMissingOrCancelledShortcutCannotBeMistakenForSuccess() async throws {
        let missing = LocationShortcutRunner(openURL: { _ in false })
        do { try await missing.run(.disable); XCTFail() } catch { }
        let launched = expectation(description: "Shortcut opened")
        var request: URL?
        let runner = LocationShortcutRunner(openURL: { request = $0; launched.fulfill(); return true })
        let task = Task { try await runner.run(.disable) }
        await fulfillment(of: [launched], timeout: 2)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request), resolvingAgainstBaseURL: false)?.queryItems)
        let callback = try XCTUnwrap(URL(string: XCTUnwrap(query.first(where: { $0.name == "x-cancel" })?.value) + "?result=cancelled"))
        XCTAssertTrue(runner.handle(callback))
        do { try await task.value; XCTFail() } catch { }
    }
}
