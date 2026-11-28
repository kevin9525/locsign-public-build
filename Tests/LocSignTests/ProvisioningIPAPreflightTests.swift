import XCTest
import ZIPFoundation
@testable import LocSign

final class ProvisioningIPAPreflightTests: XCTestCase {
    func testAcceptsOneUnencryptedArm64AppAndPreservesBundleID() throws {
        let ipa = try archive()
        XCTAssertEqual(try ProvisioningIPAPreflight().inspect(ipa), ProvisioningApp(bundleID: "com.test.app", name: "Test"))
    }

    func testRejectsCompressedResourceThatLiesAboutExpandedSize() throws {
        let ipa = try archive()
        try addMisreportedResource(to: ipa)
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(ipa))
    }

    func testImportPreviewDoesNotClaimCompatibilityForMisreportedResourceSize() throws {
        let ipa = try archive()
        try addMisreportedResource(to: ipa)
        let preview = try IPAImportPreviewInspector().inspect(ipa)
        XCTAssertEqual(preview.bundleID, "com.test.app")
        XCTAssertNotNil(preview.automaticSigningIssue)
    }

    private func addMisreportedResource(to ipa: URL) throws {
        let path = "Payload/Test.app/Resource.bin"
        func addResource() throws {
            let archive = try Archive(url: ipa, accessMode: .update)
            let data = Data(repeating: 65, count: 4096)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                Data(data[Int(position)..<min(Int(position) + size, data.count)])
            }
        }
        try addResource()
        var bytes = try Data(contentsOf: ipa)
        let name = Data(path.utf8)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let header = try XCTUnwrap((0..<(bytes.count - 46 - name.count)).first { offset in
            bytes.subdata(in: offset..<(offset + 4)) == signature
                && bytes.subdata(in: (offset + 46)..<(offset + 46 + name.count)) == name
        })
        let local = bytes[(header + 42)..<(header + 46)].reversed().reduce(0) { ($0 << 8) | Int($1) }
        // Keep deflate content and CRC intact; only the two declared lengths lie.
        bytes.replaceSubrange((header + 24)..<(header + 28), with: [1, 0, 0, 0])
        bytes.replaceSubrange((local + 22)..<(local + 26), with: [1, 0, 0, 0])
        try bytes.write(to: ipa)
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

    func testAcceptsSignedAppWithPaddingAfterTheDeclaredSuperBlob() throws {
        let executable = Self.macho(entitlements: ["get-task-allow": true], signaturePadding: 512)
        XCTAssertEqual(try ProvisioningIPAPreflight().inspect(archive(executable: executable)).bundleID, "com.test.app")
    }

    func testRejectsSignatureIndexesAndChildBlobsOutsideDeclaredLengthDespiteAllocationPadding() throws {
        let original = Self.macho(entitlements: ["get-task-allow": true], signaturePadding: 4096)
        let signature = 48 // 32-byte mach_header_64 + 16-byte LC_CODE_SIGNATURE.
        let logicalLength = Int(original[(signature + 4)..<(signature + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        func settingWord(_ value: UInt32, at offset: Int, in data: Data) -> Data {
            var result = data
            var big = value.bigEndian
            let bytes = withUnsafeBytes(of: &big) { Data($0) }
            result.replaceSubrange(offset..<(offset + 4), with: bytes)
            return result
        }
        for length in [8, logicalLength + 4097] {
            let bad = settingWord(UInt32(length), at: signature + 4, in: original)
            XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: bad)))
        }
        // The reserved bytes must not become a second source of entitlements.
        let blob = original[(signature + 20)..<(signature + logicalLength)]
        var outside = settingWord(UInt32(logicalLength), at: signature + 16, in: original)
        outside.replaceSubrange((signature + logicalLength)..<(signature + logicalLength + blob.count), with: blob)
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: outside)))

        // An otherwise unparsed child type must also stay within the SuperBlob.
        var overlongChild = settingWord(2, at: signature + 12, in: original)
        overlongChild = settingWord(UInt32(logicalLength), at: signature + 24, in: overlongChild)
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: overlongChild)))
    }

    func testPaddingDoesNotHideUnsupportedApplicationEntitlements() throws {
        let executable = Self.macho(entitlements: ["aps-environment": "development"], signaturePadding: 512)
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(executable: executable))) { error in
            XCTAssertEqual(error as? ProvisioningError, .unsupportedIPA("包含免费签名暂不支持的权限"))
        }
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

    static func macho(entitlements: [String: Any]? = nil, encrypted: Bool = false, signaturePadding: Int = 0) -> Data {
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
        if !signature.isEmpty { commands += word(0x1d) + word(16) + word(UInt32(32 + 16 + (encrypted ? 24 : 0))) + word(UInt32(signature.count + signaturePadding)) }
        if encrypted { commands += word(0x2c) + word(24) + word(0) + word(0) + word(1) + word(0) }
        let count: UInt32 = (signature.isEmpty ? 0 : 1) + (encrypted ? 1 : 0)
        var header = Data()
        let headerWords: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, count, UInt32(commands.count), 0, 0]
        for value in headerWords { header += word(value) }
        return header + commands + signature + (signature.isEmpty ? Data() : Data(repeating: 0, count: signaturePadding))
    }
}
