import XCTest
import ZIPFoundation
@testable import LocSign

final class SigningViewModelTests: XCTestCase {
    @MainActor
    func testCancelledIPAImportPreservesPreviousSelectionAndSigningChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.ipa")
        let second = root.appendingPathComponent("second.ipa")
        try Data("first source".utf8).write(to: first)
        try Data("second source".utf8).write(to: second)
        let model = SigningViewModel()
        await model.importFile(first, as: .ipa)
        model.usesPersonalBundleID = true
        model.personalBundleID = "com.personal.first"

        let importing = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.importFile(second, as: .ipa)
        }
        await importing.value

        XCTAssertEqual(model.ipaName, "first.ipa")
        XCTAssertTrue(model.usesPersonalBundleID)
        XCTAssertEqual(model.personalBundleID, "com.personal.first")
        XCTAssertFalse(model.isImporting)
    }

    @MainActor
    func testManualOutputUsesActualBundleInsteadOfAutomaticIdentifierForPendingGuard() async throws {
        for isSelf in [true, false] {
            let runningBundle = isSelf ? "com.test.app" : "org.example.running"
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let library = ManagedAppLibrary(directory: folder, runningBundleID: runningBundle, currentProfile: Data("old".utf8))
            let installer = ManualPendingInstaller()
            let model = try await signedModel(installer: installer, library: library, runningBundleID: runningBundle,
                personalTarget: isSelf ? "org.example.other" : runningBundle)
            defer { model.discardOutput() }
            let output = try XCTUnwrap(model.outputURL)
            let identity = ManagedApp.Identity(appleID: "user@example.com", teamID: "TEAM", deviceUDID: "DEVICE",
                originalBundleID: runningBundle, signingBundleID: runningBundle)
            let material = ProvisioningMaterial(privateKeyPEM: "synthetic", profileData: Data("new".utf8),
                certificateExpiry: .distantFuture, profileExpiry: .distantFuture, signingBundleID: runningBundle)
            let id = try await library.prepare(source: output, name: "Self", identity: identity, material: material)
            XCTAssertTrue(try library.markSelfInstallationAwaitingRelaunch(id: id))
            await model.importFile(try fixture("pairing-record", "plist"), as: .pairing)
            XCTAssertEqual(model.awaitingSelfVerification, isSelf)
            await model.installSignedIPA()
            let calls = await installer.calls
            XCTAssertEqual(calls, isSelf ? 0 : 1)
            XCTAssertEqual(model.installSucceeded, !isSelf)
            XCTAssertNotNil(library.apps.first?.pending)
        }
    }
    @MainActor
    func testImportingPairingRecordPreservesSignedIPA() async throws {
        let model = try await signedModel()
        defer { model.discardOutput() }
        let signedIPA = try XCTUnwrap(model.outputURL)
        await model.importFile(try fixture("pairing-record", "plist"), as: .pairing)
        XCTAssertEqual(model.outputURL, signedIPA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: signedIPA.path))
    }

    @MainActor
    func testInstallFailureAtFullProgressDoesNotReportSuccessAndNewOutputResetsSuccess() async throws {
        let model = try await signedModel(installer: ScriptedInstaller())
        defer { model.discardOutput() }
        await model.importFile(try fixture("pairing-record", "plist"), as: .pairing)
        model.deviceHost = "127.0.0.1"

        await model.installSignedIPA()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.installSucceeded)

        await model.installSignedIPA()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.installSucceeded)
        await model.sign()
        XCTAssertNotNil(model.outputURL)
        XCTAssertFalse(model.installSucceeded)
        XCTAssertEqual(model.installProgress, 0)
    }

    @MainActor
    private func signedModel(installer: any IPAInstalling = InstallCoordinator(), library: ManagedAppLibrary? = nil,
                             runningBundleID: String? = Bundle.main.bundleIdentifier, personalTarget: String? = nil) async throws -> SigningViewModel {
        let model = SigningViewModel(library: library, installer: installer, runningBundleID: runningBundleID)
        let keyURL = try fixture("test-key", "pem")
        let profileURL = try fixture("test-profile", "mobileprovision")
        let hostBinary = try XCTUnwrap(Bundle.main.executableURL)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let app = temporary.appendingPathComponent("Payload/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: hostBinary, to: app.appendingPathComponent("Demo"))
        try PlistCodec.encodeXML(["CFBundleIdentifier": "com.test.app", "CFBundleExecutable": "Demo"])
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: profileURL, to: app.appendingPathComponent("embedded.mobileprovision"))
        let ipa = temporary.appendingPathComponent("demo.ipa")
        try IPAPacker.makeZip(fromDirectory: temporary.appendingPathComponent("Payload"), to: ipa)

        await model.importFile(ipa, as: .ipa)
        XCTAssertEqual(model.ipaPreview?.bundleID, "com.test.app")
        XCTAssertNotNil(model.ipaPreview?.automaticSigningIssue,
                        "A preview warning must not block this existing manual-signing fixture")
        await model.importFile(keyURL, as: .identity)
        await model.importFile(profileURL, as: .profile)
        if let personalTarget { model.usesPersonalBundleID = true; model.personalBundleID = personalTarget }
        await model.sign()
        let signedIPA = try XCTUnwrap(model.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: signedIPA.path))
        return model
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: SigningViewModelTests.self).url(forResource: name, withExtension: ext))
    }
}

private actor ManualPendingInstaller: IPAInstalling {
    private(set) var calls = 0
    func install(ipaURL: URL, host: String, pairingData: Data, progress: @Sendable (Double) async -> Void) async throws {
        calls += 1
        await progress(1)
    }
}

private actor ScriptedInstaller: IPAInstalling {
    private var failNext = true

    func install(ipaURL: URL, host: String, pairingData: Data,
                 progress: @Sendable (Double) async -> Void) async throws {
        await progress(1)
        if failNext {
            failNext = false
            throw LocSignError.install("设备在完成前断开")
        }
    }
}
