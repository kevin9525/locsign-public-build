import XCTest
import Combine
@testable import LocSign

@MainActor
final class LocationViewModelTests: XCTestCase {
    func testInvalidManualCoordinatesNeverReachDeviceController() throws {
        let fixture = try setup()
        for input in [("not-a-number", "0"), ("nan", "0"), ("infinity", "0"),
                      ("91", "0"), ("-91", "0"), ("0", "181"), ("0", "-181")] {
            fixture.model.latitude = input.0
            fixture.model.longitude = input.1
            fixture.model.selectManual()
            fixture.model.apply()
            XCTAssertNotNil(fixture.model.error)
            XCTAssertNil(fixture.model.selected)
            XCTAssertFalse(fixture.model.isBusy)
            XCTAssertNil(fixture.settings.operationID)
            XCTAssertTrue(fixture.controller.setRequests.isEmpty)
            XCTAssertEqual(fixture.controller.clearCalls, 0)
        }
        XCTAssertNil(fixture.settings.defaults.object(forKey: "location.latitude"))
        XCTAssertNil(fixture.settings.defaults.object(forKey: "location.longitude"))
    }

    func testApplyDoesNotReportAcceptanceOrPersistCoordinateUntilDeviceSucceeds() async throws {
        let fixture = try setup(delayedSet: true)
        enterValidCoordinate(fixture.model)
        let finished = expectation(description: "Apply finished")
        let observation = idleObservation(fixture.model, finished: finished)
        defer { observation.cancel(); fixture.controller.releaseSet() }
        fixture.model.apply()
        await fulfillment(of: [fixture.controller.setStarted], timeout: 5)

        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertNotNil(fixture.settings.operationID)
        XCTAssertFalse(fixture.model.status.contains("设备已接受"))
        XCTAssertNil(fixture.model.selected)
        XCTAssertNil(fixture.settings.defaults.object(forKey: "location.latitude"))
        XCTAssertNil(fixture.settings.defaults.object(forKey: "location.longitude"))
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
        XCTAssertEqual(fixture.controller.setRequests.first?.coordinate, try LocationCoordinate(latitude: 31.2304, longitude: 121.4737))
        XCTAssertEqual(fixture.controller.setRequests.first?.host, "127.0.0.1")
        XCTAssertEqual(fixture.controller.setRequests.first?.pairingData, fixture.settings.pairing?.data)

        fixture.controller.releaseSet()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertNil(fixture.settings.operationID)
        XCTAssertNil(fixture.model.error)
        XCTAssertTrue(fixture.model.status.contains("设备已接受模拟坐标"))
        XCTAssertEqual(fixture.model.selected?.latitude, 31.2304)
        XCTAssertEqual(fixture.model.selected?.longitude, 121.4737)
        XCTAssertEqual(fixture.settings.defaults.double(forKey: "location.latitude"), 31.2304)
        XCTAssertEqual(fixture.settings.defaults.double(forKey: "location.longitude"), 121.4737)
    }

    func testFailedClearReportsUnknownStateInsteadOfRestoredLocation() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertTrue(fixture.model.status.contains("设备已接受模拟坐标"))
        fixture.controller.clearError = LocationControlError.message("Synthetic clear failure")

        await perform(fixture.model) { fixture.model.restore() }
        XCTAssertEqual(fixture.controller.clearCalls, 1)
        XCTAssertTrue(fixture.model.status.contains("未确认"))
        XCTAssertFalse(fixture.model.status.contains("设备已接受恢复真实定位"))
        XCTAssertNotNil(fixture.model.error)
        XCTAssertEqual(fixture.model.selected?.latitude, 31.2304)
        XCTAssertEqual(fixture.model.selected?.longitude, 121.4737)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertNil(fixture.settings.operationID)
    }

    func testSessionFailureInvalidatesPreviouslyAcceptedSimulation() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertTrue(fixture.model.status.contains("设备已接受模拟坐标"))
        let unknown = expectation(description: "Session failure marks location unknown")
        let observation = fixture.model.$status.dropFirst().filter { $0.contains("未确认") }.prefix(1)
            .sink { _ in unknown.fulfill() }
        defer { observation.cancel() }

        fixture.controller.onSessionFailure?("Synthetic session disconnected")
        await fulfillment(of: [unknown], timeout: 5)
        XCTAssertTrue(fixture.model.status.contains("未确认"))
        XCTAssertFalse(fixture.model.status.contains("设备已接受"))
        XCTAssertNotNil(fixture.model.error)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
        XCTAssertEqual(fixture.controller.clearCalls, 0)
    }

    func testBackgroundTransitionMarksAcceptedSimulationUnknownAndRelaunchDoesNotRestoreClaim() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertTrue(fixture.model.status.contains("设备已接受模拟坐标"))

        fixture.model.markBackground()
        XCTAssertTrue(fixture.model.status.contains("未确认"))
        XCTAssertFalse(fixture.model.status.contains("设备已接受"))
        XCTAssertEqual(fixture.model.selected?.latitude, 31.2304)
        XCTAssertEqual(fixture.model.selected?.longitude, 121.4737)
        let freshController = LocationControllerFixture()
        let reopened = LocationViewModel(settings: fixture.settings, controller: freshController)
        XCTAssertEqual(reopened.selected?.latitude, 31.2304)
        XCTAssertEqual(reopened.selected?.longitude, 121.4737)
        XCTAssertFalse(reopened.status.contains("设备已接受"))
        XCTAssertTrue(freshController.setRequests.isEmpty)
        XCTAssertEqual(freshController.clearCalls, 0)
    }

    func testApplyCompletingAfterBackgroundTransitionKeepsConnectionStateUnknown() async throws {
        let fixture = try setup(delayedSet: true)
        enterValidCoordinate(fixture.model)
        let finished = expectation(description: "Apply completed after entering background")
        let observation = idleObservation(fixture.model, finished: finished)
        defer { observation.cancel(); fixture.controller.releaseSet() }
        fixture.model.apply()
        await fulfillment(of: [fixture.controller.setStarted], timeout: 5)
        XCTAssertTrue(fixture.model.isBusy)

        fixture.model.markBackground()
        fixture.controller.releaseSet()
        await fulfillment(of: [finished], timeout: 5)

        XCTAssertTrue(fixture.model.status.contains("未确认"))
        XCTAssertFalse(fixture.model.status.contains("设备已接受模拟坐标"))
        XCTAssertNil(fixture.model.error)
        XCTAssertEqual(fixture.model.selected?.latitude, 31.2304)
        XCTAssertEqual(fixture.model.selected?.longitude, 121.4737)
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertNil(fixture.settings.operationID)
    }

    func testSharedDeviceOperationLockBlocksApplyUntilReleased() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        let token = try XCTUnwrap(fixture.settings.beginOperation())
        fixture.model.apply()
        XCTAssertTrue(fixture.controller.setRequests.isEmpty)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertEqual(fixture.settings.operationID, token)
        XCTAssertNil(fixture.model.selected)

        fixture.settings.endOperation(token)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
        XCTAssertTrue(fixture.model.status.contains("设备已接受模拟坐标"))
        XCTAssertNil(fixture.settings.operationID)
    }

    private func enterValidCoordinate(_ model: LocationViewModel) {
        model.latitude = "31.2304"
        model.longitude = "121.4737"
    }

    private func idleObservation(_ model: LocationViewModel, finished: XCTestExpectation) -> AnyCancellable {
        model.$isBusy.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
    }

    private func perform(_ model: LocationViewModel, action: () -> Void) async {
        let finished = expectation(description: "Location operation finished")
        let observation = idleObservation(model, finished: finished)
        defer { observation.cancel() }
        action()
        await fulfillment(of: [finished], timeout: 5)
    }

    @MainActor
    private struct Fixture {
        let model: LocationViewModel
        let settings: InstallationSettings
        let controller: LocationControllerFixture
    }

    private func setup(delayedSet: Bool = false) throws -> Fixture {
        let suite = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = InstallationSettings(directory: directory, defaults: defaults)
        settings.updateHost("127.0.0.1")
        let pairing = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist"))
        try settings.savePairing(data: Data(contentsOf: pairing), name: "synthetic.plist")
        let controller = LocationControllerFixture(delayedSet: delayedSet)
        return Fixture(model: LocationViewModel(settings: settings, controller: controller), settings: settings, controller: controller)
    }
}

@MainActor
private final class LocationControllerFixture: DeviceLocationControlling {
    struct SetRequest {
        let coordinate: LocationCoordinate
        let host: String
        let pairingData: Data
    }
    var onSessionFailure: (@Sendable (String) -> Void)?
    let setStarted = XCTestExpectation(description: "Location set entered controller")
    var clearError: (any Error)?
    private(set) var setRequests: [SetRequest] = []
    private(set) var clearCalls = 0
    private let delayedSet: Bool
    private var setReleased = false
    private var setContinuation: CheckedContinuation<Void, Never>?

    init(delayedSet: Bool = false) { self.delayedSet = delayedSet }
    func releaseSet() {
        setReleased = true
        setContinuation?.resume()
        setContinuation = nil
    }
    func set(_ coordinate: LocationCoordinate, host: String, pairingData: Data) async throws {
        setRequests.append(.init(coordinate: coordinate, host: host, pairingData: pairingData))
        if delayedSet && !setReleased {
            await withCheckedContinuation { continuation in
                setContinuation = continuation
                setStarted.fulfill()
            }
        } else { setStarted.fulfill() }
    }
    func clear(host: String, pairingData: Data) async throws {
        clearCalls += 1
        if let clearError { throw clearError }
    }
    func disconnect() async {}
}
