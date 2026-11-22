import XCTest
@testable import LocSign

@MainActor
final class LocationPlacesStoreTests: XCTestCase {
    func testFavoriteRenameAndDeletionSurviveRelaunchWithoutChangingCoordinates() throws {
        let defaults = try defaults()
        let store = LocationPlacesStore(defaults: defaults)
        let point = try LocationCoordinate(latitude: 31.839047, longitude: 118.815859)
        try store.saveFavorite(name: "  示例地点  ", coordinate: point, system: .gcj02, region: .mainlandChina)
        let original = try XCTUnwrap(store.favorites.first)
        XCTAssertEqual(original.name, "示例地点")
        try store.renameFavorite(id: original.id, name: "新名称")
        let reopened = LocationPlacesStore(defaults: defaults)
        let saved = try XCTUnwrap(reopened.favorites.first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.name, "新名称")
        XCTAssertEqual(saved.latitude, 31.839047)
        XCTAssertEqual(saved.longitude, 118.815859)
        XCTAssertEqual(saved.coordinateSystem, .gcj02)
        XCTAssertEqual(saved.mapRegion, .mainlandChina)
        try reopened.deleteFavorite(id: saved.id)
        XCTAssertTrue(LocationPlacesStore(defaults: defaults).favorites.isEmpty)
    }

    func testRepeatedFavoriteUpdatesNameButDifferentCoordinateSystemRemainsDistinct() throws {
        let store = LocationPlacesStore(defaults: try defaults())
        let point = try LocationCoordinate(latitude: 31, longitude: 118)
        try store.saveFavorite(name: "甲", coordinate: point, system: .wgs84, region: .mainlandChina)
        let id = try XCTUnwrap(store.favorites.first?.id)
        try store.saveFavorite(name: "乙", coordinate: point, system: .wgs84, region: .otherRegions)
        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(store.favorites.first?.id, id)
        XCTAssertEqual(store.favorites.first?.name, "乙")
        try store.saveFavorite(name: "丙", coordinate: point, system: .gcj02, region: .mainlandChina)
        XCTAssertEqual(store.favorites.count, 2, "Identical numeric coordinates in different systems represent different places")
    }

    func testRecentReuseMovesToFrontAndDeletionDoesNotRemoveFavorite() throws {
        let defaults = try defaults()
        let store = LocationPlacesStore(defaults: defaults)
        let first = try LocationCoordinate(latitude: 31, longitude: 118)
        let second = try LocationCoordinate(latitude: 32, longitude: 119)
        try store.saveFavorite(name: "收藏", coordinate: first, system: .wgs84, region: .otherRegions)
        try store.recordRecent(name: "甲", coordinate: first, system: .wgs84, region: .otherRegions)
        let originalID = try XCTUnwrap(store.recents.first?.id)
        try store.recordRecent(name: "乙", coordinate: second, system: .wgs84, region: .otherRegions)
        try store.recordRecent(name: "甲", coordinate: first, system: .wgs84, region: .otherRegions)
        XCTAssertEqual(store.recents.count, 2)
        XCTAssertEqual(store.recents.first?.id, originalID)
        try store.deleteRecent(id: originalID)
        XCTAssertEqual(store.recents.first?.latitude, 32)
        try store.clearRecents()
        let reopened = LocationPlacesStore(defaults: defaults)
        XCTAssertTrue(reopened.recents.isEmpty)
        XCTAssertEqual(reopened.favorites.count, 1)
    }

    func testInvalidNamesAndCoordinatesCannotReplaceSavedPlaces() throws {
        let defaults = try defaults()
        let store = LocationPlacesStore(defaults: defaults)
        let point = try LocationCoordinate(latitude: 31, longitude: 118)
        try store.saveFavorite(name: "保留", coordinate: point, system: .wgs84, region: .otherRegions)
        let before = defaults.data(forKey: "location.savedPlaces.v1")
        let id = try XCTUnwrap(store.favorites.first?.id)
        for name in ["", " \n ", String(repeating: "字", count: 81)] {
            XCTAssertThrowsError(try store.renameFavorite(id: id, name: name))
            XCTAssertThrowsError(try store.saveFavorite(name: name, coordinate: point, system: .wgs84, region: .otherRegions))
        }
        XCTAssertEqual(defaults.data(forKey: "location.savedPlaces.v1"), before)
        XCTAssertEqual(store.favorites.first?.name, "保留")
    }

    func testCorruptAndOutOfRangeSavedDataIsRejectedWithoutOverwritingIt() throws {
        let defaults = try defaults()
        let point = try LocationCoordinate(latitude: 31, longitude: 118)
        let store = LocationPlacesStore(defaults: defaults)
        try store.saveFavorite(name: "保留", coordinate: point, system: .gcj02, region: .mainlandChina)
        let valid = try XCTUnwrap(defaults.data(forKey: "location.savedPlaces.v1"))
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var favorites = try XCTUnwrap(invalid["favorites"] as? [[String: Any]])
        favorites[0]["latitude"] = 100
        invalid["favorites"] = favorites
        let malformed = try JSONSerialization.data(withJSONObject: invalid)
        for data in [Data("broken".utf8), malformed] {
            defaults.set(data, forKey: "location.savedPlaces.v1")
            let reopened = LocationPlacesStore(defaults: defaults)
            XCTAssertNotNil(reopened.loadError)
            XCTAssertTrue(reopened.favorites.isEmpty)
            XCTAssertThrowsError(try reopened.saveFavorite(name: "新地点", coordinate: point, system: .wgs84, region: .otherRegions))
            XCTAssertEqual(defaults.data(forKey: "location.savedPlaces.v1"), data)
        }
    }

    private func defaults() throws -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
