import XCTest
import ZIPFoundation
@testable import LocSign

final class ProvisioningSigningIdentifierTests: XCTestCase {
    func testPersonalIdentifierIsStableAndSeparatedByTeamAndOriginalApp() throws {
        let expected = "com.locsign.personal.ta1cfe821991abc80.a29da05fe51c4d844206df902f14d92e3"
        XCTAssertEqual(try ProvisioningSigningIdentifier.personal(original: "com.original.app", teamID: "TEAM12345"), expected)
        XCTAssertNotEqual(try ProvisioningSigningIdentifier.personal(original: "com.original.app", teamID: "OTHERTEAM"), expected)
        XCTAssertNotEqual(try ProvisioningSigningIdentifier.personal(original: "com.other.app", teamID: "TEAM12345"), expected)
        XCTAssertThrowsError(try ProvisioningSigningIdentifier.personal(original: "com.original.app", teamID: ""))
    }

    func testRequestInspectsOriginalEntitlementsBeforeSelectingNewIdentifier() throws {
        let ipa = try archive(entitlements: ["application-identifier": "OLDTEAM.com.original.app",
            "com.apple.developer.team-identifier": "OLDTEAM", "keychain-access-groups": ["OLDTEAM.com.original.app"]])
        let original = try Data(contentsOf: ipa)
        let plain = ProvisioningRequest(accountID: UUID(), teamID: "TEAM12345", ipaURL: ipa, deviceUDID: "SYNTHETIC")
        XCTAssertEqual(try plain.inspectedApp().bundleID, "com.original.app")
        let selected = ProvisioningRequest(accountID: plain.accountID, teamID: plain.teamID, ipaURL: ipa,
            deviceUDID: plain.deviceUDID, signingBundleID: "com.personal.test")
        XCTAssertEqual(try selected.inspectedApp().bundleID, "com.personal.test")
        XCTAssertEqual(try Data(contentsOf: ipa), original)
    }

    func testPersonalModeCannotAuthorizeUnsupportedSourcePermissions() throws {
        for entitlements: [String: Any] in [
            ["keychain-access-groups": ["OLDTEAM.com.personal.test"]],
            ["aps-environment": "development"],
            ["com.apple.security.application-groups": ["group.original"]]
        ] {
            let request = ProvisioningRequest(accountID: UUID(), teamID: "TEAM12345", ipaURL: try archive(entitlements: entitlements),
                deviceUDID: "SYNTHETIC", signingBundleID: "com.personal.test")
            XCTAssertThrowsError(try request.inspectedApp())
        }
    }

    func testInvalidIdentifierIsRejectedBeforeItCanBecomeARegistrationRequest() throws {
        for value in ["", "single", "com.*", "com..test", ".com.test", "com.test.", "com/test.app", "com.测试", String(repeating: "a", count: 252) + ".test"] {
            XCTAssertThrowsError(try ProvisioningSigningIdentifier.validate(value))
        }
        XCTAssertEqual(try ProvisioningSigningIdentifier.validate("  com.personal.test  "), "com.personal.test")
    }

    private func archive(entitlements: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("staging/Payload/Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PlistCodec.encodeXML(["CFBundleIdentifier": "com.original.app", "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"])
            .write(to: app.appendingPathComponent("Info.plist"))
        try ProvisioningIPAPreflightTests.macho(entitlements: entitlements).write(to: app.appendingPathComponent("Test"))
        let ipa = root.appendingPathComponent("test.ipa")
        try FileManager.default.zipItem(at: root.appendingPathComponent("staging"), to: ipa, shouldKeepParent: false)
        return ipa
    }
}
