import Foundation
import Combine

@MainActor
final class StorageManagementModel: ObservableObject {
    @Published private(set) var snapshot: StorageSnapshot?
    @Published private(set) var busy = false

    init(store: StorageFileStore, library: ManagedAppLibrary, settings: InstallationSettings,
         blocked: @escaping @MainActor () -> Bool = { false }) {}

    func refresh() async throws {}

    func clean(_ preview: StorageCleanupPreview) async throws -> StorageCleanupResult {
        StorageCleanupResult()
    }
}
