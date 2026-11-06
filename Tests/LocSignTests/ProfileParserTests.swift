import XCTest
@testable import LocSign

final class ProfileParserTests: XCTestCase {
    // application-identifier belongs to Entitlements; prefix and team may differ.
    func testParseSyntheticProfile() throws {
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>LocSign Dev</string>
        <key>TeamIdentifier</key><array><string>TEAM12345</string></array>
        <key>ApplicationIdentifierPrefix</key><array><string>PREFIX1234</string></array>
        <key>ExpirationDate</key><date>2026-11-11T00:00:00Z</date>
        <key>Entitlements</key><dict>
          <key>application-identifier</key><string>PREFIX1234.com.test.app</string>
          <key>get-task-allow</key><true/>
        </dict>
        <key>ProvisionedDevices</key><array><string>REDACTED-DEVICE-UDID</string></array>
        </dict></plist>
        """
        let raw = Data(repeating: 0xAB, count: 1024) + Data(payload.utf8)
        let profile = try ProfileParser.parse(raw)
        XCTAssertEqual(profile.bundleID, "com.test.app")
        XCTAssertEqual(profile.teamID, "TEAM12345")
        XCTAssertEqual(profile.entitlementsXML.contains("get-task-allow"), true)
        XCTAssertEqual(profile.deviceUDIDs, ["REDACTED-DEVICE-UDID"])
    }

    func testMissingApplicationIdentifierIsRejected() throws {
        let raw = try PlistCodec.encodeXML([
            "TeamIdentifier": ["TEAM12345"],
            "Entitlements": ["get-task-allow": true]
        ])
        XCTAssertThrowsError(try ProfileParser.parse(raw))
    }

    func testClosingTagBeforeOpeningTagDoesNotCrash() throws {
        let payload: [String: Any] = [
            "TeamIdentifier": ["TEAM12345"],
            "Entitlements": ["application-identifier": "TEAM12345.com.test.app"]
        ]
        let raw = Data("</plist>untrusted prefix".utf8) + (try PlistCodec.encodeXML(payload))
        XCTAssertEqual(try ProfileParser.parse(raw).bundleID, "com.test.app")
    }

    func testUnterminatedPlistIsRejected() {
        XCTAssertThrowsError(try ProfileParser.parse(Data("<?xml version=\"1.0\"?><plist>".utf8)))
    }

    func testWildcardProfileProducesConcreteApplicationAndKeychainIdentifiers() throws {
        let payload: [String: Any] = [
            "TeamIdentifier": ["TEAM12345"],
            "Entitlements": [
                "application-identifier": "PREFIX1234.com.test.*",
                "keychain-access-groups": ["PREFIX1234.*"],
                "get-task-allow": true
            ]
        ]
        let profile = try ProfileParser.parse(PlistCodec.encodeXML(payload))
        let xml = try profile.signingEntitlements(for: "com.test.app")
        let result = try XCTUnwrap(try PlistCodec.decode(xml) as? [String: Any])
        XCTAssertEqual(result["application-identifier"] as? String, "PREFIX1234.com.test.app")
        XCTAssertEqual(result["keychain-access-groups"] as? [String], ["PREFIX1234.com.test.app"])
        XCTAssertThrowsError(try profile.signingEntitlements(for: "com.other.app"))
    }
}
