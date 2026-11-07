import XCTest
import ZIPFoundation
@testable import LocSign

/// iOS 模拟器测试环境无 Process（NSTask 为 macOS 专属）：
/// fixture 全部预生成入库——key/cert/CMS profile（openssl cms 生成）、二进制用测试宿主 App 自己的 MachO。
/// 注意：zsign 要求 profile 为真 CMS 结构（d2i_CMS_bio 解析），纯 XML 合成品会被拒。
final class IPAPackerTests: XCTestCase {
    @MainActor
    func testExplicitSigningIdentifierRetargetsOnlyTheSignedCopy() async throws {
        let raw = try Data(contentsOf: fixture("profile-valid", "mobileprovision"))
        let original = ProvisioningMaterial(privateKeyPEM: try String(contentsOf: fixture("test-key", "pem"), encoding: .utf8),
            profileData: raw, certificateExpiry: .distantFuture, profileExpiry: .distantFuture)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["signingBundleID"] = "com.test.app"
        let material = try JSONDecoder().decode(ProvisioningMaterial.self, from: JSONSerialization.data(withJSONObject: fields))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle.main.executableURL), to: app.appendingPathComponent("Demo"))
        try PlistCodec.encodeXML(["CFBundleIdentifier": "com.original.app", "CFBundleExecutable": "Demo"])
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = root.appendingPathComponent("original.ipa")
        try IPAPacker.makeZip(fromDirectory: root.appendingPathComponent("Payload"), to: ipa)
        let originalBytes = try Data(contentsOf: ipa)
        do {
            let output = try await SigningViewModel.signProvisionedMaterial(ipa, material)
            defer { try? FileManager.default.removeItem(at: output) }
            let signed = try IPAPacker.unpack(output, into: root.appendingPathComponent("check"))
            let info = try XCTUnwrap(PlistCodec.decode(Data(contentsOf: signed.appendingPathComponent("Info.plist"))) as? [String: Any])
            XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.test.app")
            XCTAssertEqual(try Data(contentsOf: signed.appendingPathComponent("embedded.mobileprovision")), raw)
            XCTAssertTrue(SigningEngine.shared.isSigned(signed.appendingPathComponent("Demo").path))
            let claims = try signedEntitlements(Data(contentsOf: signed.appendingPathComponent("Demo")))
            XCTAssertEqual(claims["application-identifier"] as? String, "PREFIX1234.com.test.app")
            XCTAssertEqual(claims["keychain-access-groups"] as? [String], ["PREFIX1234.com.test.app"])
            XCTAssertEqual(try Data(contentsOf: ipa), originalBytes)
        } catch { XCTFail("Explicit signing identifier was not applied: \(error.localizedDescription)") }
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: IPAPackerTests.self).url(forResource: name, withExtension: ext),
                      "fixture \(name).\(ext) 缺失")
    }

    // Inspect the actual LC_CODE_SIGNATURE entitlement slot from the signed
    // simulator executable, independently of the signer's input plist.
    private func signedEntitlements(_ data: Data) throws -> [String: Any] {
        func word(_ offset: Int, big: Bool = false) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw NSError(domain: "TestMachO", code: 1) }
            let bytes = Array(data[offset..<(offset + 4)])
            return (big ? bytes : Array(bytes.reversed())).reduce(0) { ($0 << 8) | Int($1) }
        }
        XCTAssertEqual(try word(0), 0xfeedfacf)
        var cursor = 32
        for _ in 0..<(try word(16)) {
            if try word(cursor) == 0x1d {
                let signature = try word(cursor + 8)
                for index in 0..<(try word(signature + 8, big: true)) {
                    let entry = signature + 12 + index * 8
                    if try word(entry, big: true) == 5 {
                        let blob = signature + (try word(entry + 4, big: true))
                        let length = try word(blob + 4, big: true)
                        guard length >= 8, blob + length <= data.count else { throw NSError(domain: "TestMachO", code: 2) }
                        return try XCTUnwrap(PlistCodec.decode(Data(data[(blob + 8)..<(blob + length)])) as? [String: Any])
                    }
                }
            }
            cursor += try word(cursor + 4)
        }
        throw NSError(domain: "TestMachO", code: 3)
    }

    func testSignedIPARemainsReadableAfterAsyncSigningReturns() async throws {
        let keyURL = try fixture("test-key", "pem")
        let profileRaw = try Data(contentsOf: fixture("test-profile", "mobileprovision"))
        let hostBin = try XCTUnwrap(Bundle.main.executableURL, "测试宿主可执行文件缺失")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 组装假 IPA：宿主二进制作 Demo、CMS 包装的合成 profile
        let appDir = tmp.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: hostBin, to: appDir.appendingPathComponent("Demo"))
        let infoPlist = try PlistCodec.encodeXML(["CFBundleIdentifier": "com.test.app", "CFBundleExecutable": "Demo"])
        try infoPlist.write(to: appDir.appendingPathComponent("Info.plist"))
        try profileRaw.write(to: appDir.appendingPathComponent("embedded.mobileprovision"))
        let zip = tmp.appendingPathComponent("demo.ipa")
        try IPAPacker.makeZip(fromDirectory: tmp.appendingPathComponent("Payload"), to: zip)

        // unpack → 校验结构
        let unpacked = try IPAPacker.unpack(zip, into: tmp.appendingPathComponent("work"))
        XCTAssertEqual(unpacked.lastPathComponent, "Demo.app")
        print("[IPAPackerTests] PHASE: unpack 完成 \(unpacked.path)")

        // profile 解析（CMS 提取 + entitlements 生成）
        let profile = try ProfileParser.parse(profileRaw)
        XCTAssertEqual(profile.bundleID, "com.test.app")
        XCTAssertTrue(profile.entitlementsXML.contains("get-task-allow"))
        print("[IPAPackerTests] PHASE: profile 解析完成 team=\(profile.teamID)")

        // zsign 真实签名（cert 由 profile 的 DeveloperCertificates 配对）
        print("[IPAPackerTests] PHASE: 调用 Zsign.sign 前")
        let signedIPA = try await SigningEngine.shared.sign(
            ipaURL: zip, keyPEM: try String(contentsOf: keyURL, encoding: .utf8), profile: profile)
        defer { try? FileManager.default.removeItem(at: signedIPA) }
        print("[IPAPackerTests] PHASE: Zsign.sign 返回")
        XCTAssertTrue(FileManager.default.fileExists(atPath: signedIPA.path), "签名后 IPA 未生成")

        // 解包（ZIPFoundation，无外部命令）→ zsign checkSigned 验证
        print("[IPAPackerTests] PHASE: 解包签名产物前")
        let checkDir = tmp.appendingPathComponent("signed-check")
        try FileManager.default.unzipItem(at: signedIPA, to: checkDir)
        let demo = checkDir.appendingPathComponent("Payload/Demo.app/Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: demo.path), "签名 IPA 内缺 Demo 二进制")
        XCTAssertTrue(SigningEngine.shared.isSigned(demo.path), "zsign checkSigned 未识别签名")
        let embedded = try Data(contentsOf: checkDir.appendingPathComponent("Payload/Demo.app/embedded.mobileprovision"))
        XCTAssertEqual(embedded, profileRaw)
    }

    func testMalformedIPAIsRejectedWithoutAnOutput() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ipa = tmp.appendingPathComponent("broken.ipa")
        try Data("not a zip".utf8).write(to: ipa)
        let raw = try Data(contentsOf: fixture("test-profile", "mobileprovision"))
        let profile = try ProfileParser.parse(raw)
        do {
            let output = try await SigningEngine.shared.sign(ipaURL: ipa, keyPEM: "invalid", profile: profile)
            try? FileManager.default.removeItem(at: output)
            XCTFail("损坏的 IPA 不应返回成功")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
