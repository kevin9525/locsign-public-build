import XCTest
import Combine
import CoreLocation
@testable import LocSign

@MainActor
final class LocationViewModelTests: XCTestCase {
    func testImportFavoriteKeepsSelectionAndDoesNotSendDeviceRequest() throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        let beforeLatitude = fixture.model.latitude
        let beforeLongitude = fixture.model.longitude
        let data = Data(#"{"format":"LocSign.favorites","version":1,"favorites":[{"name":"导入地点","latitude":31.839047,"longitude":118.815859,"coordinateSystem":"gcj02","mapRegion":"mainlandChina"}]}"#.utf8)
        let preview = try fixture.model.previewPlacesImport(data)
        XCTAssertEqual(try fixture.model.importPlaces(preview), 1)
        XCTAssertEqual(fixture.model.latitude, beforeLatitude)
        XCTAssertEqual(fixture.model.longitude, beforeLongitude)
        XCTAssertTrue(fixture.controller.setRequests.isEmpty)
        let place = try XCTUnwrap(fixture.model.places.favorites.first)
        fixture.model.selectPlace(place)
        XCTAssertEqual(fixture.model.inputSystem, .gcj02)
        XCTAssertEqual(fixture.model.latitude, "31.839047")
        XCTAssertTrue(fixture.controller.setRequests.isEmpty)
    }

    func testImportCannotMutateFavoritesDuringLocationOrSharedDeviceOperation() async throws {
        for sharedLock in [false, true] {
            let fixture = try setup(delayedSet: true)
            enterValidCoordinate(fixture.model)
            let data = Data(#"{"format":"LocSign.favorites","version":1,"favorites":[{"name":"新地点","latitude":31,"longitude":118,"coordinateSystem":"wgs84","mapRegion":"otherRegions"}]}"#.utf8)
            let preview = try fixture.model.previewPlacesImport(data)
            var lock: UUID?
            if sharedLock { lock = fixture.settings.beginOperation() }
            else {
                fixture.model.apply()
                await fulfillment(of: [fixture.controller.setStarted], timeout: 5)
            }
            defer {
                fixture.model.cancel()
                fixture.controller.releaseSet()
                if let lock { fixture.settings.endOperation(lock) }
            }
            XCTAssertThrowsError(try fixture.model.previewPlacesImport(data)) { XCTAssertEqual($0 as? LocationPlacesError, .busy) }
            XCTAssertThrowsError(try fixture.model.importPlaces(preview)) { XCTAssertEqual($0 as? LocationPlacesError, .busy) }
            XCTAssertTrue(fixture.model.places.favorites.isEmpty)
            if !sharedLock {
                let finished = expectation(description: "Import busy fixture drained")
                let observation = idleObservation(fixture.model, finished: finished)
                fixture.model.cancel()
                fixture.controller.releaseSet()
                await fulfillment(of: [finished], timeout: 5)
                observation.cancel()
            }
        }
    }

    func testSelectingAnotherSearchResultDoesNotBorrowPreviousAcceptance() async throws {
        let fixture = try setup()
        fixture.model.selectSearchCoordinate(.init(latitude: 31, longitude: 118), countryCode: "US", name: "地点 A")
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(fixture.model.selectionState, .accepted)
        let accepted = try XCTUnwrap(fixture.model.lastAcceptedLocation)
        fixture.model.selectSearchCoordinate(.init(latitude: 32, longitude: 119), countryCode: "US", name: "地点 B")
        XCTAssertEqual(fixture.model.selectionState, .pending)
        XCTAssertEqual(fixture.model.lastAcceptedLocation, accepted)
        XCTAssertEqual(accepted.name, "地点 A")
        XCTAssertEqual(fixture.model.selectedPlaceName, "地点 B")
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
    }

    func testMapManualFavoriteAndCoordinateSystemChangesRequireApply() async throws {
        for method in 0..<4 {
            let fixture = try setup()
            fixture.model.selectSearchCoordinate(.init(latitude: 32, longitude: 119), countryCode: "US", name: "收藏 B")
            try fixture.model.saveFavorite(name: "收藏 B")
            let favorite = try XCTUnwrap(fixture.model.places.favorites.first)
            fixture.model.selectSearchCoordinate(.init(latitude: 31, longitude: 118), countryCode: "US", name: "A")
            await perform(fixture.model) { fixture.model.apply() }
            switch method {
            case 0: fixture.model.selectMapCoordinate(.init(latitude: 32, longitude: 119))
            case 1: fixture.model.latitude = "32"
            case 2: fixture.model.selectPlace(favorite)
            default: fixture.model.setInputSystem(.gcj02)
            }
            XCTAssertEqual(fixture.model.selectionState, .pending, "selection method \(method)")
            XCTAssertEqual(fixture.model.lastAcceptedLocation?.name, "A")
            XCTAssertEqual(fixture.controller.setRequests.count, 1)
        }
    }

    func testEquivalentNumericFormattingAndMapRegionKeepAcceptedSelection() async throws {
        let fixture = try setup()
        fixture.model.latitude = "31.123456789"
        fixture.model.longitude = "118"
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(fixture.model.selectionState, .accepted, "Displayed six-digit rounding must still match the accepted request")
        fixture.model.longitude = " 118.000000 "
        fixture.model.setMapRegion(.mainlandChina)
        XCTAssertEqual(fixture.model.selectionState, .accepted)
        fixture.model.latitude = "not-a-number"
        XCTAssertEqual(fixture.model.selectionState, .invalid)
    }

    func testDifferentDisplayedCoordinatesDoNotMatchAcrossRoundingBoundary() async throws {
        let fixture = try setup()
        fixture.model.latitude = "31.0000004"
        fixture.model.longitude = "118"
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(fixture.model.latitude, "31.000000")
        XCTAssertEqual(fixture.model.selectionState, .accepted)
        fixture.model.latitude = "31.0000008"
        XCTAssertEqual(fixture.model.selectionState, .pending)
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
    }

    func testFailedReplacementKeepsLastAcceptedHistoryWithoutClaimingItActive() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        let accepted = try XCTUnwrap(fixture.model.lastAcceptedLocation)
        fixture.model.latitude = "32"
        fixture.controller.setError = URLError(.networkConnectionLost)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(fixture.model.lastAcceptedLocation, accepted)
        XCTAssertEqual(fixture.model.deviceState, .unknown)
        XCTAssertEqual(fixture.model.selectionState, .pending)
        enterValidCoordinate(fixture.model)
        XCTAssertEqual(fixture.model.selectionState, .unconfirmed)
    }

    func testRestoreMakesSelectedLocationPendingAndRelaunchKeepsNoAcceptanceClaim() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        await perform(fixture.model) { fixture.model.restore() }
        XCTAssertEqual(fixture.model.deviceState, .restored)
        XCTAssertEqual(fixture.model.selectionState, .pending)
        XCTAssertNotNil(fixture.model.lastAcceptedLocation, "The last request is history, not a current device claim")
        let reopened = LocationViewModel(settings: fixture.settings, controller: LocationControllerFixture())
        XCTAssertEqual(reopened.selectionState, .pending)
        XCTAssertNil(reopened.lastAcceptedLocation)
    }

    func testBackgroundRoundTripDuringApplyDoesNotRestoreGreenState() async throws {
        let fixture = try setup(delayedSet: true)
        enterValidCoordinate(fixture.model)
        let finished = expectation(description: "Apply after background round trip")
        let observation = idleObservation(fixture.model, finished: finished)
        defer { observation.cancel(); fixture.controller.releaseSet() }
        fixture.model.apply()
        await fulfillment(of: [fixture.controller.setStarted], timeout: 5)
        fixture.model.markBackground()
        fixture.model.markForeground()
        fixture.controller.releaseSet()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(fixture.model.deviceState, .unknown)
        XCTAssertEqual(fixture.model.selectionState, .unconfirmed)
        XCTAssertNotNil(fixture.model.lastAcceptedLocation)
    }

    func testDeviceSettingsChangeDropsPreviousDeviceAcceptance() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        await fixture.model.settingsChanged()
        XCTAssertNil(fixture.model.lastAcceptedLocation)
        XCTAssertEqual(fixture.model.selectionState, .pending)
        XCTAssertEqual(fixture.model.deviceState, .unknown)
    }

    func testFavoriteSelectionAfterRelaunchOnlyPrefillsThenAppliesCorrectGPSCoordinate() async throws {
        let fixture = try setup()
        fixture.model.selectSearchCoordinate(.init(latitude: 31.839047, longitude: 118.815859), countryCode: "CN", name: "示例地点")
        try fixture.model.saveFavorite(name: "常用地点")
        let freshController = LocationControllerFixture()
        let reopened = LocationViewModel(settings: fixture.settings, controller: freshController)
        reopened.selectPlace(try XCTUnwrap(reopened.places.favorites.first))
        XCTAssertEqual(reopened.latitude, "31.839047")
        XCTAssertEqual(reopened.longitude, "118.815859")
        XCTAssertEqual(reopened.inputSystem, .gcj02)
        XCTAssertEqual(reopened.mapRegion, .mainlandChina)
        XCTAssertEqual(reopened.selected?.latitude, 31.839047)
        XCTAssertEqual(reopened.selectedPlaceName, "常用地点")
        XCTAssertTrue(reopened.places.recents.isEmpty)
        XCTAssertTrue(freshController.setRequests.isEmpty)
        XCTAssertEqual(freshController.clearCalls, 0)
        XCTAssertFalse(reopened.status.contains("设备已接受"))
        await perform(reopened) { reopened.apply() }
        XCTAssertEqual(try XCTUnwrap(freshController.setRequests.first?.coordinate.latitude), 31.841097105, accuracy: 0.00000001)
        XCTAssertEqual(try XCTUnwrap(freshController.setRequests.first?.coordinate.longitude), 118.810721382, accuracy: 0.00000001)
        XCTAssertEqual(reopened.places.recents.first?.name, "常用地点")
    }

    func testEditedCoordinatesDoNotKeepPreviousPlaceName() async throws {
        let fixture = try setup()
        fixture.model.selectSearchCoordinate(.init(latitude: 31, longitude: 118), countryCode: "US", name: "旧地点")
        XCTAssertEqual(fixture.model.selectedPlaceName, "旧地点")
        fixture.model.latitude = "32"
        XCTAssertNil(fixture.model.selectedPlaceName)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertNotEqual(fixture.model.places.recents.first?.name, "旧地点")
        XCTAssertEqual(fixture.model.places.recents.first?.latitude, 32)
        fixture.model.selectSearchCoordinate(.init(latitude: 31, longitude: 118), countryCode: "CN", name: "坐标系地点")
        fixture.model.setInputSystem(.wgs84)
        XCTAssertNil(fixture.model.selectedPlaceName)
    }

    func testCancelledApplyDoesNotAddHistoryAndBusySelectionCannotChangeTarget() async throws {
        let fixture = try setup(delayedSet: true)
        enterValidCoordinate(fixture.model)
        try fixture.model.saveFavorite(name: "收藏")
        let favorite = try XCTUnwrap(fixture.model.places.favorites.first)
        fixture.model.latitude = "32"
        let finished = expectation(description: "Cancelled apply finished")
        let observation = idleObservation(fixture.model, finished: finished)
        defer { observation.cancel(); fixture.controller.releaseSet() }
        fixture.model.apply()
        await fulfillment(of: [fixture.controller.setStarted], timeout: 5)
        fixture.model.selectPlace(favorite)
        XCTAssertEqual(fixture.model.latitude, "32")
        XCTAssertThrowsError(try fixture.model.saveFavorite(name: "操作中"))
        fixture.model.cancel()
        fixture.controller.releaseSet()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(fixture.model.places.recents.isEmpty)
        XCTAssertEqual(fixture.model.places.favorites.count, 1)
        XCTAssertNil(fixture.model.lastAcceptedLocation)
        XCTAssertEqual(fixture.model.deviceState, .unknown)
    }

    func testCorruptHistoryDoesNotTurnSuccessfulDeviceApplyIntoFailure() async throws {
        let fixture = try setup()
        let corrupt = Data("invalid".utf8)
        fixture.settings.defaults.set(corrupt, forKey: "location.savedPlaces.v1")
        let model = LocationViewModel(settings: fixture.settings, controller: fixture.controller)
        enterValidCoordinate(model)
        await perform(model) { model.apply() }
        XCTAssertTrue(model.status.contains("设备已接受"))
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.placesMessage)
        XCTAssertTrue(model.places.recents.isEmpty)
        XCTAssertEqual(fixture.settings.defaults.data(forKey: "location.savedPlaces.v1"), corrupt)
    }

    func testSuccessfulApplyPersistsOriginalCoordinatesAndSystemInRecentHistory() async throws {
        let fixture = try setup()
        fixture.model.selectSearchCoordinate(.init(latitude: 31.839047, longitude: 118.815859), countryCode: "CN")
        await perform(fixture.model) { fixture.model.apply() }
        await perform(fixture.model) { fixture.model.apply() }
        let data = try XCTUnwrap(fixture.settings.defaults.data(forKey: "location.savedPlaces.v1"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recent = try XCTUnwrap(saved["recents"] as? [[String: Any]])
        XCTAssertEqual(recent.count, 1, "Repeated applications must update one place rather than fill the history")
        let place = try XCTUnwrap(recent.first)
        XCTAssertEqual(try XCTUnwrap(place["latitude"] as? Double), 31.839047, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(place["longitude"] as? Double), 118.815859, accuracy: 0.0000001)
        XCTAssertEqual(place["coordinateSystem"] as? String, "gcj02", "History must retain input coordinates, not relabel converted GPS values")
        XCTAssertEqual(place["mapRegion"] as? String, "mainlandChina")
        XCTAssertEqual(try XCTUnwrap(fixture.controller.setRequests.last?.coordinate.latitude), 31.841097105, accuracy: 0.00000001)
    }

    func testRecentHistoryKeepsTwentyLatestPlacesAndExcludesFailedApplyAndRestore() async throws {
        let fixture = try setup()
        for offset in 0..<22 {
            fixture.model.latitude = String(30 + Double(offset) / 100)
            fixture.model.longitude = "120"
            await perform(fixture.model) { fixture.model.apply() }
        }
        let data = try XCTUnwrap(fixture.settings.defaults.data(forKey: "location.savedPlaces.v1"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recent = try XCTUnwrap(saved["recents"] as? [[String: Any]])
        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(try XCTUnwrap(recent.first?["latitude"] as? Double), 30.21, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(recent.last?["latitude"] as? Double), 30.02, accuracy: 0.0000001)
        await perform(fixture.model) { fixture.model.restore() }
        fixture.controller.setError = URLError(.cannotConnectToHost)
        fixture.model.latitude = "40"
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertEqual(fixture.settings.defaults.data(forKey: "location.savedPlaces.v1"), data)
    }

    func testRememberedAssistedModeRoutesMainApplyAndRestoreAfterRelaunch() async throws {
        let fixture = try setup()
        var events: [String] = []
        let assist = LocationNetworkAssist(defaults: fixture.settings.defaults,
            runShortcut: { events.append($0.rawValue) }, probe: { _, _ in events.append("ready") })
        let model = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        model.setConnectionMode(.assisted)
        let reopened = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        XCTAssertEqual(reopened.connectionMode, .assisted)
        XCTAssertTrue(events.isEmpty, "Remembering the mode must not start shortcuts")
        enterValidCoordinate(reopened)
        await perform(reopened) { reopened.apply() }
        XCTAssertEqual(events, ["disable", "ready", "enable"])
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
        events.removeAll()
        await perform(reopened) { reopened.restore() }
        XCTAssertEqual(events, ["disable", "ready", "enable"])
        XCTAssertEqual(fixture.controller.clearCalls, 1)
        XCTAssertNotNil(reopened.restorationNotice)
        XCTAssertNil(fixture.settings.operationID)
    }

    func testReturningToDirectModePersistsAndNeverRunsShortcuts() async throws {
        let fixture = try setup()
        let assist = LocationNetworkAssist(defaults: fixture.settings.defaults,
            runShortcut: { _ in XCTFail("Direct mode must not toggle cellular data") },
            probe: { _, _ in XCTFail("Direct mode must not use assisted readiness") })
        let model = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        model.setConnectionMode(.assisted)
        model.setConnectionMode(.direct)
        let reopened = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        XCTAssertEqual(reopened.connectionMode, .direct)
        enterValidCoordinate(reopened)
        await perform(reopened) { reopened.apply() }
        await perform(reopened) { reopened.restore() }
        XCTAssertEqual(fixture.controller.setRequests.count, 1)
        XCTAssertEqual(fixture.controller.clearCalls, 1)
    }

    func testMissingOrUnknownConnectionModeDefaultsToDirectWithoutStartingWork() throws {
        let fixture = try setup()
        XCTAssertEqual(fixture.model.connectionMode, .direct)
        fixture.settings.defaults.set("future-mode", forKey: "location.connectionMode")
        let reopened = LocationViewModel(settings: fixture.settings, controller: fixture.controller)
        XCTAssertEqual(reopened.connectionMode, .direct)
        XCTAssertTrue(fixture.controller.setRequests.isEmpty)
        XCTAssertEqual(fixture.controller.clearCalls, 0)
        XCTAssertNil(reopened.restorationNotice)
    }

    func testAssistedRestoreReadinessFailureDoesNotClearOrClaimRestoration() async throws {
        let fixture = try setup()
        var time: TimeInterval = 0
        var actions: [LocationNetworkAssist.Action] = []
        let assist = LocationNetworkAssist(defaults: fixture.settings.defaults,
            runShortcut: { actions.append($0) }, probe: { _, _ in throw URLError(.cannotConnectToHost) },
            pause: { time += 1 }, now: { time }, readinessTimeout: 2)
        let model = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        model.setConnectionMode(.assisted)
        await perform(model) { model.restore() }
        XCTAssertEqual(actions, [.disable, .enable])
        XCTAssertEqual(fixture.controller.clearCalls, 0)
        XCTAssertNil(model.restorationNotice)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.requiresCellularRestore)
        XCTAssertNil(fixture.settings.operationID)
    }

    func testRestoreNoticeIsClearedByNewOperationAndFailedRestore() async throws {
        let fixture = try setup()
        await perform(fixture.model) { fixture.model.restore() }
        XCTAssertNotNil(fixture.model.restorationNotice)
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertNil(fixture.model.restorationNotice)
        await perform(fixture.model) { fixture.model.restore() }
        XCTAssertNotNil(fixture.model.restorationNotice)
        fixture.controller.clearError = URLError(.networkConnectionLost)
        await perform(fixture.model) { fixture.model.restore() }
        XCTAssertNil(fixture.model.restorationNotice)
        XCTAssertNotNil(fixture.model.error)
    }

    func testModeCannotChangeDuringDeviceOperationOrPendingCellularRecovery() throws {
        let fixture = try setup()
        let token = try XCTUnwrap(fixture.settings.beginOperation())
        fixture.model.setConnectionMode(.assisted)
        XCTAssertEqual(fixture.model.connectionMode, .direct)
        fixture.settings.endOperation(token)
        fixture.model.setConnectionMode(.assisted)
        fixture.settings.defaults.set(true, forKey: "location.networkAssist.requiresRestore")
        fixture.model.setConnectionMode(.direct)
        XCTAssertEqual(fixture.model.connectionMode, .assisted)
        let reopened = LocationViewModel(settings: fixture.settings, controller: fixture.controller)
        XCTAssertEqual(reopened.connectionMode, .assisted)
        XCTAssertTrue(reopened.requiresCellularRestore)
    }

    func testAssistedApplyWaitsForNetworkAndUsesConvertedCoordinate() async throws {
        let fixture = try setup()
        var events: [String] = []
        let assist = LocationNetworkAssist(defaults: fixture.settings.defaults,
            runShortcut: { events.append($0.rawValue) }, probe: { _, _ in events.append("ready") })
        let model = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        model.selectSearchCoordinate(.init(latitude: 31.839047, longitude: 118.815859), countryCode: "CN")
        model.setConnectionMode(.assisted)
        await perform(model) { model.apply() }
        XCTAssertEqual(events, ["disable", "ready", "enable"])
        XCTAssertEqual(try XCTUnwrap(fixture.controller.setRequests.first?.coordinate.latitude), 31.841097105, accuracy: 0.00000001)
        XCTAssertFalse(model.requiresCellularRestore)
        XCTAssertNil(fixture.settings.operationID)
        XCTAssertEqual(model.selectionState, .unconfirmed, "Cellular switching cannot promise a sustained location session")
        XCTAssertNotNil(model.lastAcceptedLocation)
    }

    func testAssistedFailureDoesNotPersistSelectionAndKeepsRecoveryVisible() async throws {
        let fixture = try setup()
        let assist = LocationNetworkAssist(defaults: fixture.settings.defaults,
            runShortcut: { _ in throw URLError(.timedOut) }, probe: { _, _ in XCTFail() })
        let model = LocationViewModel(settings: fixture.settings, controller: fixture.controller, networkAssist: assist)
        enterValidCoordinate(model)
        model.setConnectionMode(.assisted)
        await perform(model) { model.apply() }
        XCTAssertTrue(fixture.controller.setRequests.isEmpty)
        XCTAssertNil(fixture.settings.defaults.object(forKey: "location.latitude"))
        XCTAssertTrue(model.requiresCellularRestore)
        XCTAssertNotNil(model.cellularRestoreWarning)
        XCTAssertNotNil(model.error)
        XCTAssertNil(fixture.settings.operationID)
    }

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
        XCTAssertEqual(fixture.model.selectionState, .unconfirmed)
        XCTAssertEqual(fixture.model.deviceState, .unknown)
    }

    func testBackgroundTransitionMarksAcceptedSimulationUnknownAndRelaunchDoesNotRestoreClaim() async throws {
        let fixture = try setup()
        enterValidCoordinate(fixture.model)
        await perform(fixture.model) { fixture.model.apply() }
        XCTAssertTrue(fixture.model.status.contains("设备已接受模拟坐标"))

        fixture.model.markBackground()
        fixture.model.markForeground()
        XCTAssertEqual(fixture.model.selectionState, .unconfirmed)
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
    var setError: (any Error)?
    private(set) var setRequests: [SetRequest] = []
    private(set) var clearCalls = 0
    private let delayedSet: Bool
    private var setReleased = false
    private var setContinuation: CheckedContinuation<Void, Never>?

    init(delayedSet: Bool = false) { self.delayedSet = delayedSet }
    func prepareConnection(host: String, timeout: TimeInterval) async throws {}
    func releaseSet() {
        setReleased = true
        setContinuation?.resume()
        setContinuation = nil
    }
    func set(_ coordinate: LocationCoordinate, host: String, pairingData: Data) async throws {
        if let setError { throw setError }
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
