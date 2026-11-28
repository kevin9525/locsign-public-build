import Foundation

enum LocationPlacesSort: String, CaseIterable, Identifiable {
    case saved, name
    var id: String { rawValue }
    var title: String { self == .saved ? "收藏顺序" : "名称" }
}

enum LocationPlacesBackupError: LocalizedError, Equatable {
    case invalidData, unsupportedVersion, tooLarge, stalePreview
    var errorDescription: String? {
        switch self {
        case .invalidData: return "收藏备份无效，请选择 LocSign 导出的 JSON 文件；地点名称、坐标和坐标类型必须完整有效。"
        case .unsupportedVersion: return "此备份版本暂不支持，请更新 LocSign 后重试。"
        case .tooLarge: return "备份或合并后的收藏不能超过 5000 个，备份文件不能超过 2 MB。"
        case .stalePreview: return "本地收藏已变化，请重新选择备份并核对导入预览。"
        }
    }
}

struct LocationPlacesImportPreview: Equatable {
    let existing: [SavedLocationPlace]
    let additions: [SavedLocationPlace]
    let duplicateCount: Int
    var totalCount: Int { additions.count + duplicateCount }
}

enum LocationPlacesBackup {
    static let maximumBytes = 2_097_152
    static let maximumPlaces = 5000

    private struct Header: Decodable {
        let format: String
        let version: Int
    }
    private struct Document: Codable {
        let format: String
        let version: Int
        let favorites: [Place]
    }
    /// Portable values only: record IDs belong to each device's local store.
    private struct Place: Codable {
        let name: String
        let latitude: Double
        let longitude: Double
        let coordinateSystem: LocationCoordinateSystem
        let mapRegion: LocationMapRegion

        init(_ place: SavedLocationPlace) {
            name = place.name
            latitude = place.latitude
            longitude = place.longitude
            coordinateSystem = place.coordinateSystem
            mapRegion = place.mapRegion
        }
        func validated() throws -> SavedLocationPlace {
            guard (try? LocationPlacesStore.normalizedName(name)) == name,
                  (try? LocationCoordinate(latitude: latitude, longitude: longitude)) != nil else {
                throw LocationPlacesBackupError.invalidData
            }
            return SavedLocationPlace(id: UUID(), name: name, latitude: latitude, longitude: longitude,
                                      coordinateSystem: coordinateSystem, mapRegion: mapRegion)
        }
    }

    static func encode(_ places: [SavedLocationPlace]) throws -> Data {
        guard places.count <= maximumPlaces else { throw LocationPlacesBackupError.tooLarge }
        let rows = try places.map { place -> Place in
            let row = Place(place)
            _ = try row.validated()
            return row
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(format: "LocSign.favorites", version: 1, favorites: rows))
        guard data.count <= maximumBytes else { throw LocationPlacesBackupError.tooLarge }
        return data
    }
    static func decode(_ data: Data) throws -> [SavedLocationPlace] {
        guard data.count <= maximumBytes else { throw LocationPlacesBackupError.tooLarge }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.format == "LocSign.favorites" else { throw LocationPlacesBackupError.invalidData }
            guard header.version == 1 else { throw LocationPlacesBackupError.unsupportedVersion }
            let document = try decoder.decode(Document.self, from: data)
            guard document.favorites.count <= maximumPlaces else { throw LocationPlacesBackupError.tooLarge }
            return try document.favorites.map { try $0.validated() }
        } catch let error as LocationPlacesBackupError { throw error }
        catch { throw LocationPlacesBackupError.invalidData }
    }
    static func read(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LocationPlacesBackupError.invalidData
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                guard chunk.count <= maximumBytes - data.count else { throw LocationPlacesBackupError.tooLarge }
                data.append(chunk)
            }
            try Task.checkCancellation()
            return data
        }
        let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return data
    }
}
