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

    /// `extensionProfiles` must contain exactly one profile per `.appex`, each
    /// for that extension's final identifier. Only automatic provisioning
    /// produces them; manual signing of an IPA with extensions is rejected.
    func sign(ipaURL: URL, identity: SigningIdentity, profile: ProvisioningProfileData,
              automaticProvisioning: Bool = false, signingBundleID: String? = nil,
              extensionProfiles: [ProvisioningProfileData] = []) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.signIPA(ipaURL, identity: identity, profile: profile,
                        automaticProvisioning: automaticProvisioning, signingBundleID: signingBundleID,
                        extensionProfiles: extensionProfiles))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private struct ExtensionTarget {
        let directory: URL
        let bundleID: String
        let profile: ProvisioningProfileData
    }

    private func signIPA(_ ipaURL: URL, identity: SigningIdentity,
                         profile: ProvisioningProfileData, automaticProvisioning: Bool,
                         signingBundleID: String?, extensionProfiles: [ProvisioningProfileData]) throws -> URL {
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
        let extensions = try Self.resolveExtensions(in: app, originalBundleID: originalBundleID, bundleID: bundleID,
                                                    profiles: extensionProfiles, automaticProvisioning: automaticProvisioning)
        if signingBundleID != nil {
            info["CFBundleIdentifier"] = bundleID
            try PlistCodec.encodeXML(info).write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
        }
        for target in extensions {
            // Rewrite before signing so each Info.plist hash in the seal is final.
            let url = target.directory.appendingPathComponent("Info.plist")
            guard var extensionInfo = try PlistCodec.decode(Data(contentsOf: url)) as? [String: Any] else {
                throw LocSignError.signing("扩展的应用信息无效")
            }
            if extensionInfo["CFBundleIdentifier"] as? String != target.bundleID {
                extensionInfo["CFBundleIdentifier"] = target.bundleID
                try PlistCodec.encodeXML(extensionInfo).write(to: url, options: .atomic)
            }
        }
        let exports = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            .appendingPathComponent("SignedIPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let output = exports.appendingPathComponent("\(UUID().uuidString).ipa")
        do {
            return try signAppBundle(app: app, workDir: tmp, identity: identity, profile: profile,
                                     bundleID: bundleID, extensions: extensions, outputURL: output,
                                     automaticProvisioning: automaticProvisioning)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Pairs every `.appex` with exactly one exact-identifier profile. An
    /// extension keeps its suffix under the selected app identifier.
    private static func resolveExtensions(in app: URL, originalBundleID: String, bundleID: String,
                                          profiles: [ProvisioningProfileData],
                                          automaticProvisioning: Bool) throws -> [ExtensionTarget] {
        var directories: [URL] = []
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file != app && file.pathExtension == "appex" {
                directories.append(file)
            }
        }
        guard !directories.isEmpty || !profiles.isEmpty else { return [] }
        guard automaticProvisioning else {
            throw LocSignError.signing("此 IPA 包含扩展；手动证书签名不支持扩展，请使用 Apple ID 自动申请材料")
        }
        guard directories.count == profiles.count else {
            throw LocSignError.signing("扩展描述文件数量与 IPA 中的扩展不一致，请重新申请材料")
        }
        var unused = profiles
        var targets: [ExtensionTarget] = []
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            let data = try Data(contentsOf: directory.appendingPathComponent("Info.plist"))
            guard let info = try PlistCodec.decode(data) as? [String: Any],
                  let original = info["CFBundleIdentifier"] as? String else {
                throw LocSignError.signing("扩展的应用信息无效（\(directory.lastPathComponent)）")
            }
            let target = try ProvisioningSigningIdentifier.extensionIdentifier(original, originalApp: originalBundleID,
                                                                              targetApp: bundleID)
            // Exact match only: a wildcard profile is never used for an extension.
            guard let index = unused.firstIndex(where: { $0.bundleID == target }) else {
                throw LocSignError.signing("缺少扩展 \(target) 的描述文件，请重新申请材料")
            }
            let profile = unused.remove(at: index)
            guard profile.expiry > Date() else {
                throw LocSignError.signing("扩展 \(target) 的描述文件已过期，请重新申请")
            }
            targets.append(ExtensionTarget(directory: directory, bundleID: target, profile: profile))
        }
        return targets
    }

    @discardableResult
    private func signAppBundle(app: URL, workDir: URL, identity: SigningIdentity,
                               profile: ProvisioningProfileData, bundleID: String,
                               extensions: [ExtensionTarget], outputURL: URL,
                               automaticProvisioning: Bool) throws -> URL {
        let profileFile = workDir.appendingPathComponent("embedded.mobileprovision")
        try profile.raw.write(to: profileFile)
        // The patched local Zsign dependency embeds this profile before sealing resources.
        let entsFile = workDir.appendingPathComponent("entitlements.plist")
        try profile.signingEntitlements(for: bundleID, automaticProvisioning: automaticProvisioning).write(to: entsFile)
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

        AppLogger.log(.info, "sign", "zsign 开始签名：\(app.lastPathComponent)，扩展 \(extensions.count) 个")
        let ok: Bool
        if extensions.isEmpty {
            ok = Zsign.sign(
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
        } else {
            // The app's profile comes first; Zsign selects each bundle's own
            // profile by exact application identifier and embeds it before
            // sealing that bundle's resources (see Vendor/zsign/LOCSIGN.md).
            var provisions = [profileFile.path]
            var entitlements = [entsFile.path]
            for (index, target) in extensions.enumerated() {
                let extensionProfile = workDir.appendingPathComponent("extension-\(index).mobileprovision")
                try target.profile.raw.write(to: extensionProfile)
                let extensionEntitlements = workDir.appendingPathComponent("extension-\(index)-entitlements.plist")
                try target.profile.signingEntitlements(for: target.bundleID, automaticProvisioning: automaticProvisioning)
                    .write(to: extensionEntitlements)
                provisions.append(extensionProfile.path)
                entitlements.append(extensionEntitlements.path)
            }
            ok = Zsign.sign(appPath: app.path, provisionPaths: provisions, entitlementsPaths: entitlements,
                            p12Path: keyFile.path, p12Password: password)
        }
        guard ok else { throw LocSignError.signing("zsign 签名返回失败（详见日志）") }
        AppLogger.log(.info, "sign", "zsign 签名完成")

        // Never repair bundle contents after signing: an added/replaced profile
        // invalidates the resource seal even when the Mach-O is signed.
        guard (try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))) == profile.raw else {
            throw LocSignError.signing("签名产物中的描述文件缺失或与所选材料不一致，请重新签名")
        }
        for target in extensions {
            guard (try? Data(contentsOf: target.directory.appendingPathComponent("embedded.mobileprovision"))) == target.profile.raw else {
                throw LocSignError.signing("扩展 \(target.bundleID) 的描述文件缺失或不一致，请重新签名")
            }
        }

        try IPAPacker.repack(appURL: app, outputURL: outputURL)
        return outputURL
    }

    /// 签名结果自检（测试与 UI 共用）：zsign 校验 MachO 是否含合法签名
    func isSigned(_ binaryPath: String) -> Bool {
        Zsign.checkSigned(appExecutable: binaryPath)
    }
}
