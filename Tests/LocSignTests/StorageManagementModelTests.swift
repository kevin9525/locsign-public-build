import XCTest
@testable import LocSign

@MainActor
final class StorageManagementModelTests: XCTestCase {
    func testConfirmedAndPendingLibraryFilesSurviveModelCleanup() async throws {
        let (f, library, settings) = try fixture()
        let original = f.root.appendingPathComponent("original.ipa")
        try Data(repeating: 1, count: 10).write(to: original)
        let identity = ManagedApp.Identity(appleID: "u@example.com", teamID: "T", deviceUDID: "D",
            originalBundleID: "org.example.demo", signingBundleID: "org.example.demo")
        let material = ProvisioningMaterial(privateKeyPEM: "key", profileData: Data([1]),
            certificateExpiry: .distantFuture, profileExpiry: .distantFuture)
        let id = try await library.prepare(source: original, name: "Demo", identity: identity, material: material)
        try library.confirmInstallation(id: id)
        let confirmed = try library.sourceURL(for: id)
        _ = try await library.prepare(source: original, name: "Demo", identity: identity, material: material)
        let pending = f.library.appendingPathComponent(try XCTUnwrap(library.apps.first?.pending?.sourceFile))
        let cache = try f.file(.signed, bytes: 6)
        let model = StorageManagementModel(store: f.store(), library: library, settings: settings)
        try await model.refresh()
        let report = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(report.retainedBytes, 20)
        let result = try await model.clean(report.cleanup)
        XCTAssertEqual(result.removedBytes, 6)
        XCTAssertFalse(f.exists(cache))
        XCTAssertTrue(f.exists(confirmed))
        XCTAssertTrue(f.exists(pending))
        XCTAssertEqual(library.apps.first?.pending?.sourceFile, pending.lastPathComponent)
        XCTAssertNil(settings.operationID)
        XCTAssertFalse(model.busy)
    }

    func testOperationStartingAfterPreviewBlocksCleanup() async throws {
        let (f, library, settings) = try fixture()
        let cache = try f.file(.signed, bytes: 6)
        let model = StorageManagementModel(store: f.store(), library: library, settings: settings)
        try await model.refresh()
        let preview = try XCTUnwrap(model.snapshot).cleanup
        let token = try XCTUnwrap(settings.beginOperation())
        do { _ = try await model.clean(preview); XCTFail("Busy cleanup accepted") } catch {}
        XCTAssertTrue(f.exists(cache))
        XCTAssertEqual(settings.operationID, token)
        settings.endOperation(token)
        let result = try await model.clean(preview)
        XCTAssertEqual(result.removedCount, 1)
    }

    func testSigningBusyAfterPreviewPreventsCleanup() async throws {
        let (f, library, settings) = try fixture()
        let cache = try f.file(.signed, bytes: 6)
        var blocked = false
        let model = StorageManagementModel(store: f.store(), library: library, settings: settings, blocked: { blocked })
        try await model.refresh()
        let preview = try XCTUnwrap(model.snapshot).cleanup
        blocked = true
        do { _ = try await model.clean(preview); XCTFail("Active signing ignored") } catch {}
        XCTAssertTrue(f.exists(cache))
        XCTAssertNil(settings.operationID)
    }

    func testCorruptManifestAfterPreviewPreventsAllDeletionAndReleasesLock() async throws {
        let (f, library, settings) = try fixture()
        let cache = try f.file(.signed, bytes: 6)
        let model = StorageManagementModel(store: f.store(), library: library, settings: settings)
        try await model.refresh()
        let preview = try XCTUnwrap(model.snapshot).cleanup
        try Data("broken".utf8).write(to: f.library.appendingPathComponent("apps.json"))
        do { _ = try await model.clean(preview); XCTFail("Corrupt manifest ignored") } catch {}
        XCTAssertTrue(f.exists(cache))
        XCTAssertNil(settings.operationID)
        XCTAssertFalse(model.busy)
    }

    func testMissingManifestWithSourceFilesDoesNotTreatThemAsOrphans() async throws {
        let (f, library, settings) = try fixture()
        let source = try f.file(.library, bytes: 9)
        let model = StorageManagementModel(store: f.store(), library: library, settings: settings)
        try await model.refresh()
        let report = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(report.cleanup.count, 0)
        XCTAssertFalse(report.warnings.isEmpty)
        XCTAssertTrue(f.exists(source))
    }

    private func fixture() throws -> (StorageFixture, ManagedAppLibrary, InstallationSettings) {
        let f = try StorageFixture()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: f.root)
        }
        return (f, ManagedAppLibrary(directory: f.library),
                InstallationSettings(directory: f.root.appendingPathComponent("Installation"), defaults: defaults))
    }
}
