import XCTest
@testable import LocSign

@MainActor
final class InstallationSettingsTests: XCTestCase {
    func testSavedPairingSurvivesRelaunchAndIsSharedByBothPages() async throws {
        let (settings, directory, defaults) = try makeSettings()
        let connection = ConnectionViewModel(settings: settings)
        let signing = SigningViewModel(settings: settings)
        connection.host = "10.7.0.2"
        try connection.importPairing(fixture())
        XCTAssertEqual(signing.deviceHost, "10.7.0.2")
        XCTAssertEqual(signing.pairingName, "pairing-record.plist")
        let restored = InstallationSettings(directory: directory, defaults: defaults)
        let relaunched = ConnectionViewModel(settings: restored)
        XCTAssertTrue(relaunched.canCheckPairing)
        XCTAssertEqual(relaunched.host, "10.7.0.2")
        XCTAssertEqual(restored.pairing?.data, try Data(contentsOf: fixture()))
        try settings.clearPairing()
        XCTAssertEqual(signing.pairingName, "未选择")
        XCTAssertFalse(connection.canCheckPairing)
        XCTAssertNil(InstallationSettings(directory: directory, defaults: defaults).pairing)
    }

    func testInvalidReplacementLeavesSavedPairingUsable() throws {
        let (settings, directory, defaults) = try makeSettings()
        let valid = try Data(contentsOf: fixture())
        try settings.savePairing(data: valid, name: "phone.plist")
        XCTAssertThrowsError(try settings.savePairing(data: Data("invalid".utf8), name: "invalid.plist"))
        XCTAssertEqual(InstallationSettings(directory: directory, defaults: defaults).pairing?.data, valid)
    }

    func testProviderConsentIsRestoredOnlyForTheExactEndpoint() throws {
        let (settings, directory, defaults) = try makeSettings()
        let first = AppleIDProvisioningModel(settings: settings)
        first.endpoint = "https://provider.example.com"
        first.providerAccepted = true
        first.providerEnabled = false
        let next = AppleIDProvisioningModel(settings: InstallationSettings(directory: directory, defaults: defaults))
        XCTAssertEqual(next.endpoint, "https://provider.example.com")
        XCTAssertTrue(next.providerAccepted)
        XCTAssertFalse(next.providerEnabled)
        XCTAssertTrue(next.password.isEmpty)
        next.endpoint = "https://other.example.com"
        XCTAssertFalse(next.providerAccepted)
        let changed = AppleIDProvisioningModel(settings: InstallationSettings(directory: directory, defaults: defaults))
        XCTAssertFalse(changed.providerAccepted)
    }

    func testSharedOperationBlocksPairingReplacementAndDiagnostics() async throws {
        let (settings, _, _) = try makeSettings()
        try settings.savePairing(data: Data(contentsOf: fixture()), name: "phone.plist")
        let connection = ConnectionViewModel(settings: settings, checkPairing: { _, _ in
            XCTFail("Diagnostics must not race an installation")
            throw CancellationError()
        })
        let token = try XCTUnwrap(settings.beginOperation())
        XCTAssertNil(settings.beginOperation())
        XCTAssertFalse(connection.canCheckPairing)
        XCTAssertThrowsError(try settings.clearPairing())
        connection.host = "10.7.0.99"
        XCTAssertEqual(connection.host, "10.7.0.1")
        XCTAssertEqual(settings.host, "10.7.0.1")
        await connection.checkPairing()
        settings.endOperation(token)
        XCTAssertTrue(connection.canCheckPairing)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record", withExtension: "plist"))
    }

    private func makeSettings() throws -> (InstallationSettings, URL, UserDefaults) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: directory)
        }
        return (InstallationSettings(directory: directory, defaults: defaults), directory, defaults)
    }
}
