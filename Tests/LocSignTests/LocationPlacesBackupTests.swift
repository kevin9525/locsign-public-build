import XCTest
@testable import LocSign

@MainActor
final class LocationPlacesBackupTests: XCTestCase {
    func testExportRestoresCoordinatesSystemsNamesAndOrderWithoutRecentHistory() throws {
        let source = try store()
        try source.saveFavorite(name: "大陆地点", coordinate: point(31.839047, 118.815859), system: .gcj02, region: .mainlandChina)
        try source.saveFavorite(name: "GPS地点", coordinate: point(-33.8, 151.2), system: .wgs84, region: .otherRegions)
        try source.recordRecent(name: "不导出历史", coordinate: point(40, 116), system: .wgs84, region: .otherRegions)
        let data = try source.exportFavorites()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "LocSign.favorites")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNil(json["recents"])
        let restored = try store()
        let preview = try restored.previewImport(data)
        XCTAssertEqual(preview.additions.count, 2)
        XCTAssertEqual(preview.duplicateCount, 0)
        XCTAssertEqual(try restored.importFavorites(preview), 2)
        XCTAssertEqual(restored.favorites.map(\.name), ["大陆地点", "GPS地点"])
        XCTAssertEqual(restored.favorites.map(\.latitude), [31.839047, -33.8])
        XCTAssertEqual(restored.favorites.map(\.longitude), [118.815859, 151.2])
        XCTAssertEqual(restored.favorites.map(\.coordinateSystem), [.gcj02, .wgs84])
        XCTAssertEqual(restored.favorites.map(\.mapRegion), [.mainlandChina, .otherRegions])
        XCTAssertTrue(restored.recents.isEmpty)
    }

    func testImportPreviewDoesNotWriteAndMergeRetainsLocalNameAndRegion() throws {
        let defaults = try defaults()
        let target = LocationPlacesStore(defaults: defaults)
        try target.saveFavorite(name: "本地名称", coordinate: point(31, 118), system: .wgs84, region: .otherRegions)
        try target.recordRecent(name: "历史", coordinate: point(32, 119), system: .gcj02, region: .mainlandChina)
        let local = try XCTUnwrap(target.favorites.first)
        let recents = target.recents
        let before = defaults.data(forKey: LocationPlacesStore.key)
        let data = try backup([item("外部名称", 31, 118), item("不同坐标系", 31, 118, system: "gcj02"),
                               item("新地点", 33, 120), item("文件内重复", 33, 120)])
        let preview = try target.previewImport(data)
        XCTAssertEqual(preview.totalCount, 4)
        XCTAssertEqual(preview.additions.map(\.name), ["不同坐标系", "新地点"])
        XCTAssertEqual(preview.duplicateCount, 2)
        XCTAssertEqual(defaults.data(forKey: LocationPlacesStore.key), before)
        XCTAssertEqual(try target.importFavorites(preview), 2)
        XCTAssertEqual(target.favorites.first, local)
        XCTAssertEqual(target.recents, recents)
        XCTAssertEqual(LocationPlacesStore(defaults: defaults).favorites, target.favorites)
        let again = try target.previewImport(data)
        XCTAssertEqual(again.duplicateCount, 4)
        XCTAssertEqual(try target.importFavorites(again), 0)
        XCTAssertEqual(target.favorites.count, 3)
    }

    func testSameNameAtDifferentCoordinatesIsNotADuplicate() throws {
        let target = try store()
        let preview = try target.previewImport(backup([item("同名", 30, 120), item("同名", 31, 120)]))
        XCTAssertEqual(preview.additions.count, 2)
        XCTAssertEqual(preview.duplicateCount, 0)
        try target.importFavorites(preview)
        XCTAssertEqual(Set(target.favorites.map(\.id)).count, 2)
    }

    func testInvalidOrUnknownBackupCannotPartiallyReplaceFavorites() throws {
        let defaults = try defaults()
        let target = LocationPlacesStore(defaults: defaults)
        try target.saveFavorite(name: "保留", coordinate: point(31, 118), system: .gcj02, region: .mainlandChina)
        let before = defaults.data(forKey: LocationPlacesStore.key)
        var invalid: [[String: Any]] = []
        for (key, value) in [("latitude", 91 as Any), ("longitude", -181 as Any), ("name", "   " as Any),
                             ("name", String(repeating: "字", count: 81) as Any), ("coordinateSystem", "unknown" as Any),
                             ("mapRegion", "unknown" as Any), ("latitude", "31" as Any)] {
            var row = item("错误", 31, 118)
            row[key] = value
            invalid.append(row)
        }
        var missingSystem = item("缺类型", 31, 118)
        missingSystem.removeValue(forKey: "coordinateSystem")
        invalid.append(missingSystem)
        for bad in invalid {
            let data = try backup([item("不可部分写入", 32, 119), bad])
            XCTAssertThrowsError(try target.previewImport(data))
            XCTAssertEqual(defaults.data(forKey: LocationPlacesStore.key), before)
        }
        for data in [Data("broken".utf8), try backup([], version: 99), try backup([], format: "other"),
                     Data(repeating: 32, count: 2_097_153), try backup(Array(repeating: item("太多", 0, 0), count: 5001))] {
            XCTAssertThrowsError(try target.previewImport(data))
            XCTAssertEqual(defaults.data(forKey: LocationPlacesStore.key), before)
        }
    }

    func testEmptyBackupCanBePreviewedAndDoesNotEraseExistingFavorites() throws {
        let target = try store()
        try target.saveFavorite(name: "保留", coordinate: point(31, 118), system: .wgs84, region: .otherRegions)
        let before = target.favorites
        let preview = try target.previewImport(backup([]))
        XCTAssertEqual(preview.totalCount, 0)
        XCTAssertEqual(try target.importFavorites(preview), 0)
        XCTAssertEqual(target.favorites, before)
    }

    func testChangedFavoritesRequireNewPreviewAndKeepNewLocalEdits() throws {
        let target = try store()
        try target.saveFavorite(name: "原名称", coordinate: point(31, 118), system: .wgs84, region: .otherRegions)
        let preview = try target.previewImport(backup([item("待导入", 32, 119)]))
        try target.renameFavorite(id: XCTUnwrap(target.favorites.first?.id), name: "已修改")
        XCTAssertThrowsError(try target.importFavorites(preview)) { error in
            XCTAssertEqual(error as? LocationPlacesBackupError, .stalePreview)
        }
        XCTAssertEqual(target.favorites.map(\.name), ["已修改"])
    }

    func testRecentHistoryChangesDoNotInvalidatePreviewOrGetLostOnImport() throws {
        let target = try store()
        let preview = try target.previewImport(backup([item("新收藏", 32, 119)]))
        try target.recordRecent(name: "新历史", coordinate: point(31, 118), system: .wgs84, region: .otherRegions)
        try target.importFavorites(preview)
        XCTAssertEqual(target.recents.first?.name, "新历史")
        XCTAssertEqual(target.favorites.first?.name, "新收藏")
    }

    func testCorruptLocalStorageCannotBeOverwrittenByImportOrExportedAsEmpty() throws {
        let defaults = try defaults()
        let original = Data("corrupt local data".utf8)
        defaults.set(original, forKey: LocationPlacesStore.key)
        let target = LocationPlacesStore(defaults: defaults)
        let data = try backup([item("新地点", 31, 118)])
        XCTAssertThrowsError(try target.exportFavorites()) { XCTAssertEqual($0 as? LocationPlacesError, .unavailable) }
        XCTAssertThrowsError(try target.previewImport(data)) { XCTAssertEqual($0 as? LocationPlacesError, .unavailable) }
        XCTAssertEqual(defaults.data(forKey: LocationPlacesStore.key), original)
    }

    func testSearchAndNameSortDoNotChangeSavedOrderOrIncludeHistory() throws {
        let target = try store()
        for (index, name) in ["Zulu", "bravo", "Alpha"].enumerated() {
            try target.saveFavorite(name: name, coordinate: point(Double(index), 100), system: .wgs84, region: .otherRegions)
        }
        try target.recordRecent(name: "Alpha history", coordinate: point(4, 100), system: .wgs84, region: .otherRegions)
        XCTAssertEqual(target.matchingFavorites(query: "", sort: .name).map(\.name), ["Alpha", "bravo", "Zulu"])
        XCTAssertEqual(target.matchingFavorites(query: "  ALP \n", sort: .name).map(\.name), ["Alpha"])
        XCTAssertEqual(target.matchingFavorites(query: "", sort: .saved).map(\.name), ["Zulu", "bravo", "Alpha"])
        XCTAssertTrue(target.matchingFavorites(query: "missing", sort: .saved).isEmpty)
        XCTAssertEqual(target.favorites.map(\.name), ["Zulu", "bravo", "Alpha"])
    }

    func testBackupFileReadIsBoundedAndCancelledReadDoesNotReturnData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("favorites.json")
        let data = try backup([item("测试", 31, 118)])
        try data.write(to: file)
        let read = try await LocationPlacesBackup.read(file)
        XCTAssertEqual(read, data)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await LocationPlacesBackup.read(file); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let result = await cancelled.value
        XCTAssertTrue(result)
        try Data(repeating: 32, count: 2_097_153).write(to: file)
        do { _ = try await LocationPlacesBackup.read(file); XCTFail("Oversized file must be rejected") }
        catch { XCTAssertEqual(error as? LocationPlacesBackupError, .tooLarge) }
    }

    private func item(_ name: String, _ latitude: Double, _ longitude: Double, system: String = "wgs84") -> [String: Any] {
        ["name": name, "latitude": latitude, "longitude": longitude, "coordinateSystem": system, "mapRegion": "mainlandChina"]
    }
    private func backup(_ items: [[String: Any]], version: Int = 1, format: String = "LocSign.favorites") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": format, "version": version, "favorites": items])
    }
    private func point(_ lat: Double, _ lon: Double) throws -> LocationCoordinate { try .init(latitude: lat, longitude: lon) }
    private func store() throws -> LocationPlacesStore { LocationPlacesStore(defaults: try defaults()) }
    private func defaults() throws -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
