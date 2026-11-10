import XCTest
@testable import LocSign

@MainActor
final class ManagedAppLibraryTests: XCTestCase {
    let identity = ManagedApp.Identity(appleID: "user@example.com", teamID: "TEAM", deviceUDID: "DEVICE",
        originalBundleID: "org.example.demo", signingBundleID: "org.example.personal")

    func testRetainedSourceSurvivesDeletionAndRelaunchButPendingIsNotSuccess() async throws {
        let (library, folder, source) = try setup()
        let id = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        try FileManager.default.removeItem(at: source)
        let reopened = ManagedAppLibrary(directory: folder)
        let row = try XCTUnwrap(reopened.apps.first)
        XCTAssertEqual(row.id, id)
        XCTAssertNil(row.installedAt)
        XCTAssertNil(row.profileExpiry)
        XCTAssertEqual(try Data(contentsOf: reopened.sourceURL(for: id)), Data("original IPA".utf8))
        try reopened.confirmInstallation(id: id, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(reopened.apps.first?.profileExpiry, Date(timeIntervalSince1970: 100))
        XCTAssertNotNil(ManagedAppLibrary(directory: folder).apps.first?.installedAt)
    }

    func testFailedRenewalPreservesConfirmedExpiryAndOriginalSource() async throws {
        let (library, folder, source) = try setup()
        let id = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        try library.confirmInstallation(id: id)
        let oldSource = try library.sourceURL(for: id)
        try Data("new original".utf8).write(to: source)
        let second = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(200))
        XCTAssertEqual(id, second)
        XCTAssertEqual(library.apps.first?.profileExpiry, Date(timeIntervalSince1970: 100))
        try library.fail(id: id, message: "network lost")
        let reopened = ManagedAppLibrary(directory: folder)
        XCTAssertEqual(reopened.apps.first?.profileExpiry, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try reopened.sourceURL(for: id), oldSource)
        XCTAssertEqual(try Data(contentsOf: oldSource), Data("original IPA".utf8))
    }

    func testFailedManifestWriteKeepsPreviousSourceAndRecord() async throws {
        let (library, folder, source) = try setup()
        let id = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        try library.confirmInstallation(id: id)
        let original = try library.sourceURL(for: id)
        // A directory at the manifest destination makes the atomic file commit fail.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("apps.json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("apps.json"), withIntermediateDirectories: false)
        do { _ = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(200)); XCTFail("commit succeeded") }
        catch { }
        XCTAssertEqual(library.apps.first?.profileExpiry, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try Data(contentsOf: original), Data("original IPA".utf8))
    }

    func testCorruptManifestCannotBeSilentlyOverwrittenAndRemoveLeavesUserFile() async throws {
        let (library, folder, source) = try setup()
        let id = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        try library.confirmInstallation(id: id)
        let owned = try library.sourceURL(for: id)
        try library.remove(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try Data("invalid manifest".utf8).write(to: folder.appendingPathComponent("apps.json"))
        let broken = ManagedAppLibrary(directory: folder)
        XCTAssertNotNil(broken.loadError)
        do { _ = try await broken.prepare(source: source, name: "Demo", identity: identity, material: material(100)); XCTFail("corruption ignored") }
        catch { }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("apps.json")), "invalid manifest")
    }

    func testSelfUpdateRecoveryRequiresExactProposedProfileAndRunningIdentity() async throws {
        let (_, folder, source) = try setup()
        let library = ManagedAppLibrary(directory: folder, runningBundleID: identity.signingBundleID, currentProfile: Data([9]))
        _ = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        try library.reconcileSelf(bundleID: "org.other", embeddedProfile: Data([1]))
        XCTAssertNil(library.apps.first?.installedAt)
        try library.reconcileSelf(bundleID: identity.signingBundleID, embeddedProfile: Data([2]))
        XCTAssertNil(library.apps.first?.installedAt)
        try library.reconcileSelf(bundleID: identity.signingBundleID, embeddedProfile: Data([1]))
        XCTAssertNil(library.apps.first?.installedAt, "Same launch cannot confirm its own interrupted attempt")
        let reopened = ManagedAppLibrary(directory: folder, runningBundleID: identity.signingBundleID, currentProfile: Data([1]))
        try reopened.reconcileSelf(bundleID: identity.signingBundleID, embeddedProfile: Data([1]))
        XCTAssertNotNil(reopened.apps.first?.installedAt)
    }

    func testSelfInstallReusingCurrentProfileCannotProveReplacementAfterRelaunch() async throws {
        let (_, folder, source) = try setup()
        let library = ManagedAppLibrary(directory: folder, runningBundleID: identity.signingBundleID, currentProfile: Data([1]))
        _ = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        let reopened = ManagedAppLibrary(directory: folder, runningBundleID: identity.signingBundleID, currentProfile: Data([1]))
        try reopened.reconcileSelf(bundleID: identity.signingBundleID, embeddedProfile: Data([1]))
        XCTAssertNil(reopened.apps.first?.installedAt)
        XCTAssertNotNil(reopened.apps.first?.pending)
    }

    func testManifestDoesNotPersistPrivateKeyOrProfileContents() async throws {
        let (library, folder, source) = try setup()
        _ = try await library.prepare(source: source, name: "Demo", identity: identity, material: material(100))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("apps.json"))) as? [String: Any])
        let rows = try XCTUnwrap(json["apps"] as? [[String: Any]])
        let pending = try XCTUnwrap(rows.first?["pending"] as? [String: Any])
        XCTAssertNil(pending["privateKeyPEM"])
        XCTAssertNil(pending["profileData"])
        XCTAssertEqual((pending["profileSHA256"] as? String)?.count, 64)
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent("apps.json")).contains("never store this"))
    }

    private func material(_ expiry: TimeInterval) -> ProvisioningMaterial {
        .init(privateKeyPEM: "never store this", profileData: Data([1]), certificateExpiry: Date(timeIntervalSince1970: 1000),
            profileExpiry: Date(timeIntervalSince1970: expiry))
    }
    private func setup() throws -> (ManagedAppLibrary, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("user.ipa")
        try Data("original IPA".utf8).write(to: source)
        let folder = root.appendingPathComponent("Library")
        return (ManagedAppLibrary(directory: folder), folder, source)
    }
}
