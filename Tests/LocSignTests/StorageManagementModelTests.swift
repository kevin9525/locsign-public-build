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

    func testSecondSigningInstanceHoldsSharedLockUntilCancelledImportDrains() async throws {
        let (f, library, settings) = try fixture()
        let cache = try f.file(.signed, bytes: 6)
        let source = f.root.appendingPathComponent("input.ipa")
        try Data([1]).write(to: source)
        let store = f.store()
        let primary = SigningViewModel(settings: settings)
        let model = StorageManagementModel(store: store, library: library, settings: settings, blocked: { primary.busy })
        let preview = try store.scan(apps: []).cleanup
        let gate = StorageInspectionGate()
        let secondary = SigningViewModel(settings: settings, inspectPreview: { _ in
            gate.entered.fulfill()
            _ = gate.release.wait(timeout: .now() + 10)
            return IPAImportPreview(name: "Demo", bundleID: "org.example.demo", version: nil, build: nil,
                minimumOSVersion: nil, fileSize: 1, extensions: [], automaticSigningIssue: nil)
        })
        let work = Task { await secondary.importFile(source, as: .ipa) }
        defer { gate.release.signal() }
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertNotNil(settings.operationID)
        let overlap = await primary.importFile(source, as: .ipa)
        XCTAssertFalse(overlap)
        do { _ = try await model.clean(preview); XCTFail("Second signing instance was ignored") } catch {}
        secondary.cancelImport()
        XCTAssertNotNil(settings.operationID, "Cancellation must drain the worker before releasing the lock")
        gate.release.signal()
        let imported = await work.value
        XCTAssertFalse(imported)
        XCTAssertTrue(f.exists(cache))
        XCTAssertNil(settings.operationID)
    }

    func testUncachedIdentifierInspectionAlsoLocksAcrossSigningInstances() async throws {
        let (f, _, settings) = try fixture()
        let source = f.root.appendingPathComponent("input.ipa")
        try Data([1]).write(to: source)
        let gate = StorageInspectionGate()
        let secondary = SigningViewModel(settings: settings, inspectBundleID: { _ in
            gate.entered.fulfill()
            _ = gate.release.wait(timeout: .now() + 10)
            throw LocSignError.signing("inspection failed")
        }, inspectPreview: { _ in throw LocSignError.signing("preview unavailable") })
        _ = await secondary.importFile(source, as: .ipa)
        let work = Task { await secondary.restoreSigningIdentifier(teamID: "TEAM") }
        defer { gate.release.signal() }
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertNotNil(settings.operationID)
        XCTAssertTrue(SigningViewModel(settings: settings).busy)
        gate.release.signal()
        await work.value
        XCTAssertNil(settings.operationID)
        XCTAssertNotNil(secondary.error)
    }

    func testDeletedManifestAfterPreviewBlocksCleanupOfPreviouslyKnownSources() async throws {
        let (f, library, settings) = try fixture()
        let cache = try f.file(.signed, bytes: 6)
        let source = try f.file(.library, bytes: 9)
        try Data("{\"version\":1,\"apps\":[]}".utf8).write(to: f.library.appendingPathComponent("apps.json"))
        library.reload()
        let store = f.store()
        let model = StorageManagementModel(store: store, library: library, settings: settings)
        let preview = try store.scan(apps: []).cleanup
        try FileManager.default.removeItem(at: f.library.appendingPathComponent("apps.json"))
        do { _ = try await model.clean(preview); XCTFail("Missing manifest ignored") } catch {}
        XCTAssertTrue(f.exists(cache))
        XCTAssertTrue(f.exists(source))
        XCTAssertNil(settings.operationID)
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

private final class StorageInspectionGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "inspection entered")
    let release = DispatchSemaphore(value: 0)
}
