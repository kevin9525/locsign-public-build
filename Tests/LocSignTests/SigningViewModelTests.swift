import XCTest
import ZIPFoundation
@testable import LocSign

final class SigningViewModelTests: XCTestCase {
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
    private func signedModel(installer: any IPAInstalling = InstallCoordinator()) async throws -> SigningViewModel {
        let model = SigningViewModel(installer: installer)
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
        await model.importFile(keyURL, as: .identity)
        await model.importFile(profileURL, as: .profile)
        await model.sign()
        let signedIPA = try XCTUnwrap(model.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: signedIPA.path))
        return model
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: SigningViewModelTests.self).url(forResource: name, withExtension: ext))
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
