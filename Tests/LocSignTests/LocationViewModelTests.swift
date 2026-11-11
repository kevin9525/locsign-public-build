import XCTest
import Combine
import CoreLocation
@testable import LocSign

@MainActor
final class LocationViewModelTests: XCTestCase {
    func testMainlandSearchSelectionIsConvertedOnlyAtDeviceBoundaryAndSurvivesRelaunch() async throws {
        let fixture = try setup()
        let point = CLLocationCoordinate2D(latitude: 31.839047, longitude: 118.815859)
        fixture.model.selectSearchCoordinate(point, countryCode: "CN")
        XCTAssertEqual(fixture.model.inputSystem, .gcj02)
        XCTAssertEqual(fixture.model.mapRegion, .mainlandChina)
        for _ in 0..<2 { await perform(fixture.model) { fixture.model.apply() } }
        XCTAssertEqual(fixture.controller.setRequests.count, 2)
        for request in fixture.controller.setRequests {
            XCTAssertEqual(request.coordinate.latitude, 31.841097105, accuracy: 0.00000001)
            XCTAssertEqual(request.coordinate.longitude, 118.810721382, accuracy: 0.00000001)
        }
        XCTAssertEqual(fixture.model.selected?.latitude, point.latitude)
        XCTAssertEqual(fixture.model.selected?.longitude, point.longitude)
        XCTAssertEqual(fixture.model.latitude, "31.839047")
        XCTAssertEqual(fixture.settings.defaults.double(forKey: "location.latitude"), point.latitude)
        let reopenedController = LocationControllerFixture()
        let reopened = LocationViewModel(settings: fixture.settings, controller: reopenedController)
        XCTAssertEqual(reopened.inputSystem, .gcj02)
        XCTAssertEqual(reopened.selected?.longitude, point.longitude)
        await perform(reopened) { reopened.apply() }
        let resent = try XCTUnwrap(reopenedController.setRequests.first?.coordinate)
        XCTAssertEqual(resent.latitude, 31.841097105, accuracy: 0.00000001)
        XCTAssertEqual(resent.longitude, 118.810721382, accuracy: 0.00000001)
    }

    func testManualGPSInputIsNotConvertedTwiceButDisplaysOnMainlandMap() async throws {
        let fixture = try setup()
        fixture.model.setMapRegion(.mainlandChina)
        fixture.model.latitude = "31.841097"
        fixture.model.longitude = "118.810721"
        fixture.model.setInputSystem(.wgs84)
        await perform(fixture.model) { fixture.model.apply() }
        let sent = try XCTUnwrap(fixture.controller.setRequests.first?.coordinate)
        XCTAssertEqual(sent.latitude, 31.841097)
        XCTAssertEqual(sent.longitude, 118.810721)
        XCTAssertEqual(try XCTUnwrap(fixture.model.selected?.latitude), 31.839047, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(fixture.model.selected?.longitude), 118.815859, accuracy: 0.000001)
    }

    func testMapTapUsesExplicitMapRegion() async throws {
        let fixture = try setup()
        fixture.model.setMapRegion(.mainlandChina)
        fixture.model.selectMapCoordinate(.init(latitude: 31.839047, longitude: 118.815859))
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(try XCTUnwrap(fixture.controller.setRequests.first?.coordinate.latitude), 31.841097105, accuracy: 0.00000001)
    }

    func testSearchOutsideMainlandDoesNotUseBoundingBoxToInferCoordinateSystem() async throws {
        for (country, point) in [("HK", CLLocationCoordinate2D(latitude: 22.3193, longitude: 114.1694)),
                                 ("MO", CLLocationCoordinate2D(latitude: 22.1987, longitude: 113.5439)),
                                 ("TW", CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)),
                                 ("GB", CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278))] {
            let fixture = try setup()
            fixture.model.selectSearchCoordinate(point, countryCode: country)
            await perform(fixture.model) { fixture.model.apply() }
            XCTAssertEqual(fixture.model.mapRegion, .otherRegions)
            XCTAssertEqual(fixture.model.inputSystem, .wgs84)
            let sent = try XCTUnwrap(fixture.controller.setRequests.first?.coordinate)
            XCTAssertEqual(sent.latitude, point.latitude, accuracy: 0.000001)
            XCTAssertEqual(sent.longitude, point.longitude, accuracy: 0.000001)
        }
    }

    func testLegacySavedCoordinatesKeepTheirOriginalGPSMeaning() throws {
        let fixture = try setup()
        fixture.settings.defaults.set(31.841097, forKey: "location.latitude")
        fixture.settings.defaults.set(118.810721, forKey: "location.longitude")
        fixture.settings.defaults.removeObject(forKey: "location.coordinateSystem")
        let reopened = LocationViewModel(settings: fixture.settings, controller: LocationControllerFixture())
        XCTAssertEqual(reopened.inputSystem, .wgs84)
        XCTAssertEqual(reopened.latitude, "31.841097")
        XCTAssertEqual(reopened.longitude, "118.810721")
    }

    func testChangingDisplayedMapRegionDoesNotChangeDeviceCoordinateOrInputType() async throws {
        let fixture = try setup()
        fixture.model.selectSearchCoordinate(.init(latitude: 31.839047, longitude: 118.815859), countryCode: "CN")
        fixture.model.setMapRegion(.otherRegions)
        XCTAssertEqual(fixture.model.inputSystem, .gcj02)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(try XCTUnwrap(fixture.controller.setRequests.first?.coordinate.latitude), 31.841097105, accuracy: 0.00000001)
        XCTAssertEqual(try XCTUnwrap(fixture.model.selected?.latitude), 31.841097105, accuracy: 0.00000001)
    }

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
        defaults.set(LocationMapRegion.otherRegions.rawValue, forKey: "location.mapRegion")
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
