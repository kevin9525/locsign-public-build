import Foundation

enum StorageFileUsage: Equatable, Sendable {
    case available(Int64), missing, unavailable
}

struct StorageAppUsage: Identifiable, Sendable {
    let id: UUID
    let name: String
    let source: StorageFileUsage?
    let pending: StorageFileUsage?
}

struct StorageCleanupPreview: Sendable {
    var bytes: Int64 = 0
    var count: Int = 0
}

struct StorageSnapshot: Sendable {
    var apps: [StorageAppUsage] = []
    var retainedBytes: Int64 = 0
    var signedBytes: Int64 = 0
    var importedBytes: Int64 = 0
    var orphanBytes: Int64 = 0
    var warnings: [String] = []
    var cleanup = StorageCleanupPreview()
}

struct StorageCleanupResult: Sendable {
    var removedCount = 0
    var removedBytes: Int64 = 0
    var skippedCount = 0
    var failedCount = 0
}

struct StorageFileStore: Sendable {
    init(libraryDirectory: URL, signedDirectory: URL, temporaryDirectory: URL) {}

    func scan(apps: [ManagedApp], libraryReadable: Bool = true) throws -> StorageSnapshot {
        StorageSnapshot()
    }

    func clean(_ preview: StorageCleanupPreview, apps: [ManagedApp], libraryReadable: Bool = true) throws -> StorageCleanupResult {
        StorageCleanupResult()
    }
}
