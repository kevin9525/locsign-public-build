import XCTest
import ZIPFoundation
@testable import LocSign

final class IPAImportPreviewTests: XCTestCase {
    func testReadsMetadataAndDirectExtensionsWithoutDirectoryEntries() throws {
        let ipa = try fixture(extensions: ["Widget", "Share"])
        let preview = try IPAImportPreviewInspector().inspect(ipa)
        XCTAssertEqual(preview.name, "示例应用")
        XCTAssertEqual(preview.bundleID, "com.test.preview")
        XCTAssertEqual(preview.version, "2.3")
        XCTAssertEqual(preview.build, "42")
        XCTAssertEqual(preview.minimumOSVersion, "17.0")
        XCTAssertEqual(preview.fileSize, Int64(try Data(contentsOf: ipa).count))
        XCTAssertEqual(preview.extensions.map(\.name), ["Share", "Widget"])
        XCTAssertEqual(preview.extensions.map(\.bundleID), ["com.test.preview.share", "com.test.preview.widget"])
        XCTAssertNil(preview.automaticSigningIssue)
    }

    func testUnsupportedBinaryKeepsMetadataAndExplainsAutomaticSigningLimit() throws {
        for executable in [ProvisioningIPAPreflightTests.macho(encrypted: true),
                           ProvisioningIPAPreflightTests.macho(entitlements: ["aps-environment": "development"])] {
            let preview = try IPAImportPreviewInspector().inspect(fixture(binary: executable))
            XCTAssertEqual(preview.name, "示例应用")
            XCTAssertEqual(preview.bundleID, "com.test.preview")
            XCTAssertFalse(try XCTUnwrap(preview.automaticSigningIssue).isEmpty)
        }
    }

    func testMissingOrWrongMetadataFallsBackWithoutInventingVersion() throws {
        let preview = try IPAImportPreviewInspector().inspect(fixture(info: [
            "CFBundleName": "Fallback", "CFBundleDisplayName": "  ",
            "CFBundleVersion": 42, "CFBundleShortVersionString": "\n"
        ]))
        XCTAssertEqual(preview.name, "Fallback")
        XCTAssertNil(preview.bundleID)
        XCTAssertNil(preview.version)
        XCTAssertNil(preview.build)
        XCTAssertNil(preview.minimumOSVersion)
        XCTAssertNotNil(preview.automaticSigningIssue)
    }

    func testMoreThanNineExtensionsRemainVisibleWithAutomaticSigningWarning() throws {
        let preview = try IPAImportPreviewInspector().inspect(fixture(extensions: (0..<10).map { "E\($0)" }))
        XCTAssertEqual(preview.extensions.count, 10)
        XCTAssertTrue(try XCTUnwrap(preview.automaticSigningIssue).contains("扩展超过"))
    }

    func testExtensionWithoutInfoIsCountedOnceAndUsesItsDirectoryName() throws {
        let ipa = try fixture(extra: ["Payload/Demo.app/PlugIns/Missing.appex/Executable": Data(),
                                     "Payload/Demo.app/PlugIns/Missing.appex/Resource": Data()])
        let preview = try IPAImportPreviewInspector().inspect(ipa)
        XCTAssertEqual(preview.extensions.count, 1)
        XCTAssertEqual(preview.extensions.first?.name, "Missing")
        XCTAssertNil(preview.extensions.first?.bundleID)
        XCTAssertNotNil(preview.automaticSigningIssue)
    }

    func testRejectsAmbiguousMainAppsAndUnsafeArchivePaths() throws {
        for extra in ["Payload/Other.app/File", "Payload/Demo.app/info.plist", "../escape",
                      "Payload//Demo.app/Foo", "Payload/Demo.app/../Foo"] {
            XCTAssertThrowsError(try IPAImportPreviewInspector().inspect(fixture(extra: [extra: Data()])))
        }
    }

    func testRejectsOversizedMainPlistBeforeReadingIt() throws {
        let ipa = try fixture(info: ["CFBundleName": String(repeating: "x", count: 1_048_577)])
        XCTAssertThrowsError(try IPAImportPreviewInspector().inspect(ipa))
    }

    func testCancelledInspectionDoesNotBecomeCompatibilityWarning() async throws {
        let ipa = try fixture()
        let work = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try IPAImportPreviewInspector().inspect(ipa); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await work.value
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testImportPublishesNewPreviewAndClearsItWhenNextPreviewCannotBeRead() async throws {
        let first = try fixture(extensions: ["Widget"])
        let model = SigningViewModel()
        await model.importFile(first, as: .ipa)
        XCTAssertEqual(model.ipaPreview?.name, "示例应用")
        XCTAssertNil(model.ipaPreviewError)
        let invalid = first.deletingLastPathComponent().appendingPathComponent("invalid.ipa")
        try Data("invalid archive".utf8).write(to: invalid)
        await model.importFile(invalid, as: .ipa)
        XCTAssertEqual(model.ipaName, "invalid.ipa")
        XCTAssertNil(model.ipaPreview)
        XCTAssertNotNil(model.ipaPreviewError)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testFailedCopyPreservesExistingPreview() async throws {
        let first = try fixture()
        let model = SigningViewModel()
        await model.importFile(first, as: .ipa)
        let preview = try XCTUnwrap(model.ipaPreview)
        await model.importFile(first.deletingLastPathComponent().appendingPathComponent("missing.ipa"), as: .ipa)
        XCTAssertEqual(model.ipaPreview, preview)
        XCTAssertEqual(model.ipaName, first.lastPathComponent)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testCancellationDuringInspectionDrainsWorkerAndPreservesOldSelection() async throws {
        let first = try fixture()
        let second = first.deletingLastPathComponent().appendingPathComponent("second.ipa")
        try Data("replacement".utf8).write(to: second)
        let gate = PreviewInspectionGate()
        let model = SigningViewModel(inspectPreview: { url in
            if try Data(contentsOf: url) == Data("replacement".utf8) {
                gate.record(url)
                _ = gate.release.wait(timeout: .now() + 10)
                // Return despite cancellation: the consumer must still discard it.
                return IPAImportPreview(name: "Late", bundleID: "com.test.late", version: nil, build: nil,
                    minimumOSVersion: nil, fileSize: 11, extensions: [], automaticSigningIssue: nil)
            }
            return try IPAImportPreviewInspector().inspect(url)
        })
        await model.importFile(first, as: .ipa)
        let previous = model.ipaPreview
        let work = Task { await model.importFile(second, as: .ipa) }
        defer { gate.release.signal() }
        await fulfillment(of: [gate.entered], timeout: 3)
        work.cancel()
        XCTAssertTrue(model.isImporting)
        XCTAssertEqual(model.ipaName, first.lastPathComponent)
        gate.release.signal()
        await work.value
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.ipaPreview, previous)
        XCTAssertEqual(model.ipaName, first.lastPathComponent)
        let staged = try XCTUnwrap(gate.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    private func fixture(info: [String: Any]? = nil, binary: Data? = nil,
                         extensions: [String] = [], extra: [String: Data] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ipa = root.appendingPathComponent("fixture.ipa")
        let archive = try Archive(url: ipa, accessMode: .create)
        var files = extra
        files["Payload/Demo.app/Info.plist"] = try PlistCodec.encodeXML(info ?? [
            "CFBundleDisplayName": "示例应用", "CFBundleIdentifier": "com.test.preview", "CFBundleExecutable": "Demo",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.3", "CFBundleVersion": "42", "MinimumOSVersion": "17.0"
        ])
        files["Payload/Demo.app/Demo"] = binary ?? ProvisioningIPAPreflightTests.macho()
        for name in extensions {
            let path = "Payload/Demo.app/PlugIns/\(name).appex/"
            files[path + "Info.plist"] = try PlistCodec.encodeXML([
                "CFBundleName": name, "CFBundleIdentifier": "com.test.preview.\(name.lowercased())",
                "CFBundleExecutable": name, "CFBundlePackageType": "XPC!"
            ])
            files[path + name] = ProvisioningIPAPreflightTests.macho()
        }
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                Data(data[Int(position)..<min(Int(position) + size, data.count)])
            }
        }
        return ipa
    }
}

private final class PreviewInspectionGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "preview inspection entered")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedURL: URL?
    var url: URL? { lock.lock(); defer { lock.unlock() }; return storedURL }
    func record(_ url: URL) {
        lock.lock(); storedURL = url; lock.unlock()
        entered.fulfill()
    }
}
