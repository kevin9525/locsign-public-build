import XCTest
@testable import LocSign

final class StorageFileStoreTests: XCTestCase {
    // These tests catch lost reference protection, overly broad deletion and
    // stale previews using real files, with independently specified byte counts.
    func testReportsConfirmedAndPendingSourcesWithoutDoubleCountingSharedFiles() throws {
        let f = try fixture()
        let current = try f.file(.library, bytes: 11)
        let pending = try f.file(.library, bytes: 7)
        let orphan = try f.file(.library, bytes: 5)
        _ = try f.file(.signed, bytes: 13)
        _ = try f.file(.imported, bytes: 17)
        let app = row(source: current.lastPathComponent, pending: pending.lastPathComponent)
        let second = row(source: current.lastPathComponent)
        let store = f.store()
        let snapshot = try store.scan(apps: [app, second])
        XCTAssertEqual(snapshot.apps.count, 2)
        XCTAssertEqual(snapshot.apps.first?.source, .available(11))
        XCTAssertEqual(snapshot.apps.first?.pending, .available(7))
        XCTAssertEqual(snapshot.retainedBytes, 18)
        XCTAssertEqual(snapshot.orphanBytes, 5)
        XCTAssertEqual(snapshot.signedBytes, 13)
        XCTAssertEqual(snapshot.importedBytes, 17)
        XCTAssertEqual(snapshot.cleanup.bytes, 35)
        XCTAssertEqual(snapshot.cleanup.count, 3)
        let result = try store.clean(snapshot.cleanup, apps: [app, second])
        XCTAssertEqual(result.removedBytes, 35)
        XCTAssertTrue(f.exists(current))
        XCTAssertTrue(f.exists(pending))
        XCTAssertFalse(f.exists(orphan))
    }

    func testCleansOnlyRecognizedFilesAndLeavesUnknownDirectoriesAndLinks() throws {
        let f = try fixture()
        let oldImport = try f.file(.imported, bytes: 3)
        let oldSigned = try f.file(.signed, bytes: 4)
        let oldSource = try f.file(.library, bytes: 5)
        let unknown = f.temporary.appendingPathComponent("user.ipa")
        try Data([1]).write(to: unknown)
        let directory = f.temporary.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let nested = directory.appendingPathComponent("keep.ipa")
        try Data([2]).write(to: nested)
        let link = f.signed.appendingPathComponent(UUID().uuidString + ".ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unknown)
        let store = f.store()
        let report = try store.scan(apps: [])
        let result = try store.clean(report.cleanup, apps: [])
        XCTAssertEqual(result.removedCount, 3)
        XCTAssertEqual(result.removedBytes, 12)
        for url in [oldImport, oldSigned, oldSource] { XCTAssertFalse(f.exists(url)) }
        for url in [unknown, nested, link] { XCTAssertTrue(f.exists(url)) }
    }

    func testFilesCreatedAfterStartupStayProtectedEvenWithOldDates() throws {
        let f = try fixture()
        _ = try f.file(.signed, bytes: 2)
        let store = f.store()
        let currentImport = try f.file(.imported, bytes: 7)
        let currentSigned = try f.file(.signed, bytes: 9)
        let currentSource = try f.file(.library, bytes: 11)
        for url in [currentImport, currentSigned, currentSource] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        }
        let report = try store.scan(apps: [])
        XCTAssertEqual(report.cleanup.bytes, 2)
        XCTAssertEqual(report.importedBytes, 7)
        XCTAssertEqual(report.signedBytes, 11)
        let result = try store.clean(report.cleanup, apps: [])
        XCTAssertEqual(result.removedCount, 1)
        for url in [currentImport, currentSigned, currentSource] { XCTAssertTrue(f.exists(url)) }
    }

    func testNewReferencesAreRecheckedAtConfirmation() throws {
        let f = try fixture()
        let source = try f.file(.library, bytes: 5)
        let pending = try f.file(.library, bytes: 7)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        XCTAssertEqual(preview.count, 2)
        let result = try store.clean(preview, apps: [row(source: source.lastPathComponent, pending: pending.lastPathComponent)])
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertTrue(f.exists(source))
        XCTAssertTrue(f.exists(pending))
    }

    func testReplacementBeforeFirstScanNeverBecomesAStartupCandidate() throws {
        let f = try fixture()
        let path = try f.file(.signed, bytes: 8)
        let store = f.store()
        try Data(repeating: 9, count: 8).write(to: path, options: .atomic)
        let report = try store.scan(apps: [])
        XCTAssertEqual(report.signedBytes, 8)
        XCTAssertEqual(report.cleanup.count, 0)
        _ = try store.clean(report.cleanup, apps: [])
        XCTAssertEqual(try Data(contentsOf: path), Data(repeating: 9, count: 8))
    }

    func testPartialDeletionFailureReportsOnlyFilesActuallyRemoved() throws {
        let f = try fixture()
        let blocked = try f.file(.signed, bytes: 7)
        let removable = try f.file(.imported, bytes: 3)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.signed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.signed.path) }
        let result = try store.clean(preview, apps: [])
        XCTAssertEqual(result.removedBytes, 3)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(f.exists(blocked))
        XCTAssertFalse(f.exists(removable))
    }

    func testDirectoryAlreadyLinkedAtStartupIsNeverScannedForCleanup() throws {
        let f = try fixture()
        let path = try f.file(.signed, bytes: 7)
        let moved = f.root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: f.signed, to: moved)
        try FileManager.default.createSymbolicLink(at: f.signed, withDestinationURL: moved)
        let store = f.store()
        let report = try store.scan(apps: [])
        XCTAssertEqual(report.cleanup.count, 0)
        XCTAssertFalse(report.warnings.isEmpty)
        _ = try store.clean(report.cleanup, apps: [])
        XCTAssertTrue(f.exists(moved.appendingPathComponent(path.lastPathComponent)))
    }

    func testReplacementAtSamePathIsNotDeletedFromOldPreview() throws {
        let f = try fixture()
        let path = try f.file(.signed, bytes: 8)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        try Data(repeating: 9, count: 8).write(to: path, options: .atomic)
        let result = try store.clean(preview, apps: [])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(try Data(contentsOf: path), Data(repeating: 9, count: 8))
        XCTAssertEqual(try store.scan(apps: []).cleanup.count, 0)
    }

    func testLinkSwappedAfterPreviewIsPreservedAlongWithItsTarget() throws {
        let f = try fixture()
        let path = try f.file(.signed, bytes: 4)
        let outside = f.root.appendingPathComponent("outside.ipa")
        try Data([3, 4]).write(to: outside)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        let result = try store.clean(preview, apps: [])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(f.exists(path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([3, 4]))
    }

    func testDirectorySwappedAfterPreviewCannotRedirectDeletion() throws {
        let f = try fixture()
        let path = try f.file(.signed, bytes: 4)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        let moved = f.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: f.signed, to: moved)
        try FileManager.default.createSymbolicLink(at: f.signed, withDestinationURL: moved)
        let result = try store.clean(preview, apps: [])
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(f.exists(moved.appendingPathComponent(path.lastPathComponent)))
    }

    func testRepeatCleanupDoesNotClaimSpaceTwice() throws {
        let f = try fixture()
        _ = try f.file(.signed, bytes: 9)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        XCTAssertEqual(try store.clean(preview, apps: []).removedBytes, 9)
        let repeated = try store.clean(preview, apps: [])
        XCTAssertEqual(repeated.removedBytes, 0)
        XCTAssertEqual(repeated.removedCount, 0)
        XCTAssertEqual(try store.scan(apps: []).cleanup.count, 0)
    }

    func testUnreadableLibraryDisablesCleanupAndPreservesCache() throws {
        let f = try fixture()
        let cache = try f.file(.signed, bytes: 3)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        let unavailable = try store.scan(apps: [], libraryReadable: false)
        XCTAssertEqual(unavailable.cleanup.count, 0)
        XCTAssertFalse(unavailable.warnings.isEmpty)
        XCTAssertThrowsError(try store.clean(preview, apps: [], libraryReadable: false))
        XCTAssertTrue(f.exists(cache))
    }

    func testMissingSourceIsReportedWithoutTreatingItAsZeroBytes() throws {
        let f = try fixture()
        let report = try f.store().scan(apps: [row(source: UUID().uuidString + ".ipa")])
        XCTAssertEqual(report.apps.first?.source, .missing)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testForeignStoreCannotUseAnotherStoresPreview() throws {
        let f = try fixture()
        let cache = try f.file(.signed, bytes: 3)
        let first = f.store()
        let preview = try first.scan(apps: []).cleanup
        XCTAssertThrowsError(try f.store().clean(preview, apps: []))
        XCTAssertTrue(f.exists(cache))
    }

    func testCancelledCleanupDoesNotDeleteFiles() async throws {
        let f = try fixture()
        let cache = try f.file(.signed, bytes: 3)
        let store = f.store()
        let preview = try store.scan(apps: []).cleanup
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try store.clean(preview, apps: []); XCTFail("Cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(f.exists(cache))
        }
        await task.value
    }

    private func row(source: String?, pending: String? = nil) -> ManagedApp {
        var app = ManagedApp(id: UUID(), name: "Demo", identity: .init(appleID: "user@example.com", teamID: "TEAM",
            deviceUDID: "DEVICE", originalBundleID: "org.example.demo", signingBundleID: "org.example.demo"), sourceFile: source)
        if let pending {
            app.pending = .init(sourceFile: pending, profileExpiry: .distantFuture, certificateExpiry: .distantFuture,
                profileSHA256: "hash", attemptedLaunchID: UUID(), replacesCurrentProfile: false)
        }
        return app
    }

    private func fixture() throws -> StorageFixture {
        let result = try StorageFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: result.root) }
        return result
    }
}

struct StorageFixture: Sendable {
    enum Kind { case library, signed, imported }
    let root: URL
    var library: URL { root.appendingPathComponent("Apps") }
    var signed: URL { root.appendingPathComponent("SignedIPAs") }
    var temporary: URL { root.appendingPathComponent("tmp") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for folder in [library, signed, temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
    func file(_ kind: Kind, bytes: Int) throws -> URL {
        let parent = kind == .library ? library : kind == .signed ? signed : temporary
        let name = (kind == .imported ? "import-" : "") + UUID().uuidString + ".ipa"
        let url = parent.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }
    func store() -> StorageFileStore {
        StorageFileStore(libraryDirectory: library, signedDirectory: signed, temporaryDirectory: temporary)
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
