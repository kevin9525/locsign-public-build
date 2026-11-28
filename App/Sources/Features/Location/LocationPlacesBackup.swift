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
        case .tooLarge: return "备份最多包含 5000 个收藏，文件不能超过 2 MB。"
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

    static func encode(_ places: [SavedLocationPlace]) throws -> Data {
        throw LocationPlacesBackupError.invalidData
    }
    static func decode(_ data: Data) throws -> [SavedLocationPlace] {
        throw LocationPlacesBackupError.invalidData
    }
    static func read(_ url: URL) async throws -> Data {
        throw LocationPlacesBackupError.invalidData
    }
}
