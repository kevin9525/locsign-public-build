import Foundation
import Combine

/// A place the user saved or recently applied. Coordinates are the values the
/// user entered or selected, in `coordinateSystem`; they are never relabelled
/// after conversion, so reapplying converts exactly as the first time did.
struct SavedLocationPlace: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let latitude: Double
    let longitude: Double
    let coordinateSystem: LocationCoordinateSystem
    var mapRegion: LocationMapRegion

    var coordinate: LocationCoordinate? { try? LocationCoordinate(latitude: latitude, longitude: longitude) }

    /// Identical numbers in different coordinate systems are different places.
    func matches(_ point: LocationCoordinate, system: LocationCoordinateSystem) -> Bool {
        latitude == point.latitude && longitude == point.longitude && coordinateSystem == system
    }
}

enum LocationPlacesError: LocalizedError, Equatable {
    case invalidName
    case unavailable
    case notFound
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidName: return "名称不能为空，且不超过 \(LocationPlacesStore.maximumNameLength) 个字"
        case .unavailable: return "已保存的地点数据无法读取，为避免覆盖，暂不保存新的收藏或历史"
        case .notFound: return "地点已不存在，请刷新后重试"
        case .busy: return "正在应用或恢复定位，完成后再修改收藏"
        }
    }
}

/// Favorites plus the 20 most recent successful applications, stored as one
/// JSON value. Every change writes the complete new value before publishing
/// it. Unreadable or invalid saved data is never overwritten.
@MainActor
final class LocationPlacesStore: ObservableObject {
    nonisolated static let key = "location.savedPlaces.v1"
    nonisolated static let recentLimit = 20
    nonisolated static let maximumNameLength = 80

    @Published private(set) var favorites: [SavedLocationPlace] = []
    @Published private(set) var recents: [SavedLocationPlace] = []
    /// Set when saved data exists but cannot be used; all writes are refused.
    @Published private(set) var loadError: String?
    private let defaults: UserDefaults

    private struct Stored: Codable, Sendable {
        var favorites: [SavedLocationPlace]
        var recents: [SavedLocationPlace]
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            try Self.validate(stored)
            favorites = stored.favorites
            recents = stored.recents
        } catch {
            loadError = LocationPlacesError.unavailable.localizedDescription
        }
    }

    nonisolated static func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumNameLength else { throw LocationPlacesError.invalidName }
        return trimmed
    }

    func saveFavorite(name: String, coordinate: LocationCoordinate, system: LocationCoordinateSystem,
                      region: LocationMapRegion) throws {
        let name = try Self.normalizedName(name)
        var next = favorites
        if let index = next.firstIndex(where: { $0.matches(coordinate, system: system) }) {
            next[index].name = name
            next[index].mapRegion = region
        } else {
            next.append(.init(id: UUID(), name: name, latitude: coordinate.latitude, longitude: coordinate.longitude,
                              coordinateSystem: system, mapRegion: region))
        }
        try commit(favorites: next, recents: recents)
    }

    func renameFavorite(id: UUID, name: String) throws {
        let name = try Self.normalizedName(name)
        var next = favorites
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw LocationPlacesError.notFound }
        next[index].name = name
        try commit(favorites: next, recents: recents)
    }

    func deleteFavorite(id: UUID) throws {
        guard favorites.contains(where: { $0.id == id }) else { throw LocationPlacesError.notFound }
        try commit(favorites: favorites.filter { $0.id != id }, recents: recents)
    }

    /// Moves an existing entry for the same place to the front (keeping its id)
    /// or inserts a new one, then keeps only the latest `recentLimit` entries.
    func recordRecent(name: String, coordinate: LocationCoordinate, system: LocationCoordinateSystem,
                      region: LocationMapRegion) throws {
        let name = try Self.normalizedName(name)
        var next = recents
        let entry: SavedLocationPlace
        if let index = next.firstIndex(where: { $0.matches(coordinate, system: system) }) {
            var existing = next.remove(at: index)
            existing.name = name
            existing.mapRegion = region
            entry = existing
        } else {
            entry = .init(id: UUID(), name: name, latitude: coordinate.latitude, longitude: coordinate.longitude,
                          coordinateSystem: system, mapRegion: region)
        }
        next.insert(entry, at: 0)
        try commit(favorites: favorites, recents: Array(next.prefix(Self.recentLimit)))
    }

    func deleteRecent(id: UUID) throws {
        guard recents.contains(where: { $0.id == id }) else { throw LocationPlacesError.notFound }
        try commit(favorites: favorites, recents: recents.filter { $0.id != id })
    }

    func clearRecents() throws { try commit(favorites: favorites, recents: []) }

    func matchingFavorites(query: String, sort: LocationPlacesSort) -> [SavedLocationPlace] { favorites }

    func exportFavorites() throws -> Data { throw LocationPlacesBackupError.invalidData }

    func previewImport(_ data: Data) throws -> LocationPlacesImportPreview {
        throw LocationPlacesBackupError.invalidData
    }

    @discardableResult
    func importFavorites(_ preview: LocationPlacesImportPreview) throws -> Int {
        throw LocationPlacesBackupError.invalidData
    }

    private func commit(favorites: [SavedLocationPlace], recents: [SavedLocationPlace]) throws {
        guard loadError == nil else { throw LocationPlacesError.unavailable }
        let stored = Stored(favorites: favorites, recents: recents)
        try Self.validate(stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(stored), forKey: Self.key)
        self.favorites = favorites
        self.recents = recents
    }

    nonisolated private static func validate(_ stored: Stored) throws {
        guard stored.recents.count <= recentLimit else { throw LocationPlacesError.unavailable }
        for place in stored.favorites + stored.recents {
            guard place.coordinate != nil, (try? normalizedName(place.name)) == place.name else {
                throw LocationPlacesError.unavailable
            }
        }
        // Ids are unique within each list; favorites and recents are independent.
        for list in [stored.favorites, stored.recents] {
            guard Set(list.map(\.id)).count == list.count else { throw LocationPlacesError.unavailable }
        }
    }
}
