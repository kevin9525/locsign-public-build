import XCTest
import ZIPFoundation
@testable import LocSign

final class ProvisioningIPAPreflightTests: XCTestCase {
    func testAcceptsOneUnencryptedArm64AppAndPreservesBundleID() throws {
        let ipa = try archive()
        XCTAssertEqual(try ProvisioningIPAPreflight().inspect(ipa), ProvisioningApp(bundleID: "com.test.app", name: "Test"))
    }

    func testRejectsMultipleAppsExtensionsNestedAppsAndInvalidExecutable() throws {
        for extra in ["Payload/Other.app/Info.plist", "Payload/Test.app/PlugIns/Ext.appex/Info.plist", "Payload/Test.app/Nested.app/Info.plist"] {
            XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(extra: extra)))
        }
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: Data("not macho".utf8))))
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executableName: "../escape")))
    }

    func testRejectsUnsupportedEntitlementsAndEncryptedOrMalformedMachO() throws {
        let unsupported: [[String: Any]] = [
            ["com.apple.security.application-groups": ["group.test"]],
            ["aps-environment": "development"],
            ["com.apple.developer.associated-domains": ["applinks:example.com"]],
            ["keychain-access-groups": ["TEAM12345.other.app"]]
        ]
        for entitlements in unsupported {
            XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: Self.macho(entitlements: entitlements))))
        }
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: Self.macho(encrypted: true))))
        var malformed = Self.macho()
        malformed.replaceSubrange(16..<20, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: malformed)))
    }

    func testReadsSignedEntitlementsAndRejectsUnsignedMalformedEntitlementBlob() throws {
        let supported: [String: Any] = ["application-identifier": "OLDTEAM.com.test.app", "com.apple.developer.team-identifier": "OLDTEAM", "get-task-allow": true, "keychain-access-groups": ["OLDTEAM.com.test.app"]]
        XCTAssertEqual(try ProvisioningIPAPreflight().inspect(archive(executable: Self.macho(entitlements: supported))).bundleID, "com.test.app")
        var data = Self.macho(entitlements: supported)
        data.removeLast(5)
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: data)))
    }

    private func archive(executable: Data? = nil, extra: String? = nil, executableName: String = "Test") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let app = staging.appendingPathComponent("Payload/Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.test.app", "CFBundleExecutable": executableName, "CFBundleDisplayName": "Test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try (executable ?? Self.macho()).write(to: app.appendingPathComponent("Test"))
        if let extra {
            let url = staging.appendingPathComponent(extra)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let ipa = root.appendingPathComponent("fixture.ipa")
        try FileManager.default.zipItem(at: staging, to: ipa, shouldKeepParent: false)
        return ipa
    }

    static func macho(entitlements: [String: Any]? = nil, encrypted: Bool = false) -> Data {
        func word(_ value: UInt32, big: Bool = false) -> Data {
            var value = big ? value.bigEndian : value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var signature = Data()
        if let entitlements {
            let plist = try! PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            let blob = word(0xfade7171, big: true) + word(UInt32(plist.count + 8), big: true) + plist
            signature = word(0xfade0cc0, big: true) + word(UInt32(blob.count + 20), big: true) + word(1, big: true) + word(5, big: true) + word(20, big: true) + blob
        }
        var commands = Data()
        if !signature.isEmpty { commands += word(0x1d) + word(16) + word(UInt32(32 + 16 + (encrypted ? 24 : 0))) + word(UInt32(signature.count)) }
        if encrypted { commands += word(0x2c) + word(24) + word(0) + word(0) + word(1) + word(0) }
        let count: UInt32 = (signature.isEmpty ? 0 : 1) + (encrypted ? 1 : 0)
        var header = Data()
        let headerWords: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, count, UInt32(commands.count), 0, 0]
        for value in headerWords { header += word(value) }
        return header + commands + signature
    }
}
