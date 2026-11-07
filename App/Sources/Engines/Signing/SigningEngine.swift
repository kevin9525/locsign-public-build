import Foundation
import Zsign

enum SigningIdentity {
    case pem(String)
    case pkcs12(Data, password: String)
}

final class SigningEngine {
    static let shared = SigningEngine()
    private let queue = DispatchQueue(label: "com.locsign.signing", qos: .userInitiated)

    /// 权威入口（异步）。流程：unpack → 写 profile/entitlements/key → zsign 签名（cert 由
    /// profile 的 DeveloperCertificates 自动配对）→ repack。
    /// 注：原计划 ldid 方案已废弃（全系依赖 OpenSSL），现役后端为 khcrysalis/Zsign-Package。
    func sign(ipaURL: URL, keyPEM: String, profile: ProvisioningProfileData) async throws -> URL {
        try await sign(ipaURL: ipaURL, identity: .pem(keyPEM), profile: profile)
    }

    func sign(ipaURL: URL, identity: SigningIdentity, profile: ProvisioningProfileData,
              restrictKeychainToApplication: Bool = false, signingBundleID: String? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.signIPA(ipaURL, identity: identity, profile: profile,
                        restrictKeychainToApplication: restrictKeychainToApplication, signingBundleID: signingBundleID))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func signIPA(_ ipaURL: URL, identity: SigningIdentity,
                         profile: ProvisioningProfileData, restrictKeychainToApplication: Bool,
                         signingBundleID: String?) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = try IPAPacker.unpack(ipaURL, into: tmp.appendingPathComponent("work"))
        let infoData = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard var info = try PlistCodec.decode(infoData) as? [String: Any],
              let originalBundleID = info["CFBundleIdentifier"] as? String else {
            throw LocSignError.signing("IPA 的应用信息无效")
        }
        let bundleID = try signingBundleID.map(ProvisioningSigningIdentifier.validate) ?? originalBundleID
        guard profile.permits(bundleIdentifier: bundleID) else {
            throw LocSignError.signing("IPA 的 Bundle ID 与描述文件不匹配")
        }
        guard profile.expiry > Date() else {
            throw LocSignError.signing("描述文件已过期，请重新申请")
        }
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file != app && file.pathExtension == "appex" {
                throw LocSignError.signing("此 IPA 包含扩展；需要为扩展配置独立描述文件，当前版本尚未支持")
            }
        }
        if signingBundleID != nil {
            info["CFBundleIdentifier"] = bundleID
            try PlistCodec.encodeXML(info).write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
        }
        let exports = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            .appendingPathComponent("SignedIPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let output = exports.appendingPathComponent("\(UUID().uuidString).ipa")
        do {
            return try signAppBundle(app: app, workDir: tmp, identity: identity, profile: profile,
                                     bundleID: bundleID, outputURL: output, restrictKeychainToApplication: restrictKeychainToApplication)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    @discardableResult
    private func signAppBundle(app: URL, workDir: URL, identity: SigningIdentity,
                               profile: ProvisioningProfileData, bundleID: String, outputURL: URL,
                               restrictKeychainToApplication: Bool) throws -> URL {
        let profileFile = workDir.appendingPathComponent("embedded.mobileprovision")
        try profile.raw.write(to: profileFile)
        // The profile passed to zsign is also the profile that must ship inside the app bundle.
        // Without this replacement, zsign can produce a signed Mach-O with no embedded profile.
        try profile.raw.write(to: app.appendingPathComponent("embedded.mobileprovision"), options: [.atomic])
        let entsFile = workDir.appendingPathComponent("entitlements.plist")
        try profile.signingEntitlements(for: bundleID, restrictKeychainToApplication: restrictKeychainToApplication).write(to: entsFile)
        let keyFile = workDir.appendingPathComponent("identity")
        let password: String
        switch identity {
        case .pem(let key):
            try Data(key.utf8).write(to: keyFile, options: [.atomic, .completeFileProtection])
            password = ""
        case .pkcs12(let data, let secret):
            try data.write(to: keyFile, options: [.atomic, .completeFileProtection])
            password = secret
        }

        AppLogger.log(.info, "sign", "zsign 开始签名：\(app.lastPathComponent)")
        let ok = Zsign.sign(
            appPath: app.path,
            provisionPath: profileFile.path,
            p12Path: keyFile.path,      // zsign 底层支持 PEM 私钥；cert 从 profile 的 DeveloperCertificates 配对
            p12Password: password,
            entitlementsPath: entsFile.path,
            adhoc: false,
            removeProvision: false,     // 保留 embedded.mobileprovision 供安装器读取
            // ZsignC invokes this block unconditionally even though Swift marks it optional.
            completion: { _ in }
        )
        guard ok else { throw LocSignError.signing("zsign 签名返回失败（详见日志）") }
        AppLogger.log(.info, "sign", "zsign 签名完成")

        // Zsign may remove the profile while rewriting the bundle. Restore the
        // exact profile selected by the caller before packaging the result.
        try profile.raw.write(to: app.appendingPathComponent("embedded.mobileprovision"),
                              options: [.atomic])

        try IPAPacker.repack(appURL: app, outputURL: outputURL)
        return outputURL
    }

    /// 签名结果自检（测试与 UI 共用）：zsign 校验 MachO 是否含合法签名
    func isSigned(_ binaryPath: String) -> Bool {
        Zsign.checkSigned(appExecutable: binaryPath)
    }
}
