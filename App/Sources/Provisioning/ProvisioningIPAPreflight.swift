import Foundation
import ZIPFoundation

struct ProvisioningApp: Sendable, Equatable {
    let bundleID: String
    let name: String
}

struct ProvisioningIPAPreflight: Sendable {
    func inspect(_ ipaURL: URL) throws -> ProvisioningApp {
        try Task.checkCancellation()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? fm.removeItem(at: work) }
        var protected = work
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try protected.setResourceValues(resources)

        let archive: Archive
        do { archive = try Archive(url: ipaURL, accessMode: .read) }
        catch { throw unsupported("归档无效") }
        var paths = Set<String>()
        var total: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains("\0"),
                  !components.contains(".."), !components.contains("."), entry.type != .symlink,
                  paths.insert(entry.path.lowercased()).inserted,
                  paths.count <= 50_000, entry.uncompressedSize <= 2_147_483_648,
                  total <= 2_147_483_648 - entry.uncompressedSize else { throw unsupported("归档结构或大小不受支持") }
            total += entry.uncompressedSize
        }
        let app = try IPAPacker.unpack(ipaURL, into: work.appendingPathComponent("unpacked"))
        let payload = app.deletingLastPathComponent()
        let mainApps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard mainApps.count == 1,
              let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw unsupported("只支持一个主 App")
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard !["app", "appex"].contains(url.pathExtension.lowercased()),
                  url.lastPathComponent.lowercased() != "plugins",
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw unsupported("暂不支持扩展、嵌套 App 或符号链接")
            }
        }
        let infoData = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard infoData.count <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String,
              bundle.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("/"),
              !executable.contains("\\"), !executable.contains("\0") else { throw unsupported("应用信息不完整") }
        let binary = app.appendingPathComponent(executable)
        guard try binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw unsupported("缺少主程序")
        }
        try inspectMachO(Data(contentsOf: binary, options: .mappedIfSafe), bundleID: bundle)
        try Task.checkCancellation()
        return ProvisioningApp(bundleID: bundle,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent)
    }

    private func inspectMachO(_ data: Data, bundleID: String) throws {
        guard data.count >= 32, try word(data, 0) == 0xfeedfacf,
              try word(data, 4) == 0x0100000c, try word(data, 12) == 2 else {
            throw unsupported("只支持未加密的单一 arm64 主程序")
        }
        let count = Int(try word(data, 16)), size = Int(try word(data, 20))
        guard count <= 4096, size <= data.count - 32 else { throw unsupported("主程序结构损坏") }
        let end = 32 + size
        var cursor = 32
        var signature: (Int, Int)?
        for _ in 0..<count {
            guard cursor <= end - 8 else { throw unsupported("主程序命令损坏") }
            let command = try word(data, cursor), length = Int(try word(data, cursor + 4))
            guard length >= 8, length % 4 == 0, length <= end - cursor else { throw unsupported("主程序命令长度无效") }
            if command == 0x2c || command == 0x21 {
                guard length >= (command == 0x2c ? 24 : 20), try word(data, cursor + 16) == 0 else {
                    throw unsupported("主程序仍被加密，请使用可重新签名的 IPA")
                }
            } else if command == 0x1d {
                guard length == 16, signature == nil else { throw unsupported("代码签名结构无效") }
                signature = (Int(try word(data, cursor + 8)), Int(try word(data, cursor + 12)))
            }
            cursor += length
        }
        guard cursor == end else { throw unsupported("主程序命令总长度无效") }
        if let (offset, length) = signature {
            guard offset >= end, length >= 12, offset <= data.count, length <= data.count - offset else {
                throw unsupported("代码签名数据不完整")
            }
            try inspectSignature(Data(data[offset..<(offset + length)]), bundleID: bundleID)
        }
    }

    private func inspectSignature(_ data: Data, bundleID: String) throws {
        guard try word(data, 0, big: true) == 0xfade0cc0,
              Int(try word(data, 4, big: true)) == data.count else { throw unsupported("代码签名容器无效") }
        let count = Int(try word(data, 8, big: true))
        guard count <= 1024, count <= (data.count - 12) / 8 else { throw unsupported("代码签名索引无效") }
        var types = Set<UInt32>()
        for index in 0..<count {
            let type = try word(data, 12 + index * 8, big: true)
            let offset = Int(try word(data, 16 + index * 8, big: true))
            guard types.insert(type).inserted, offset >= 12 + count * 8, offset <= data.count - 8 else {
                throw unsupported("代码签名索引越界")
            }
            let length = Int(try word(data, offset + 4, big: true))
            guard length >= 8, length <= data.count - offset else { throw unsupported("代码签名数据损坏") }
            if type == 7 { throw unsupported("暂不支持 DER 格式权限声明，请使用无额外权限的 IPA") }
            if type == 5 {
                guard try word(data, offset, big: true) == 0xfade7171,
                      let entitlements = try PropertyListSerialization.propertyList(from: Data(data[(offset + 8)..<(offset + length)]), format: nil) as? [String: Any]
                else { throw unsupported("权限声明无效") }
                let allowed: Set<String> = ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"]
                guard Set(entitlements.keys).isSubset(of: allowed) else { throw unsupported("包含免费签名暂不支持的权限") }
                if let value = entitlements["application-identifier"] {
                    guard let appID = value as? String, appID.hasSuffix("." + bundleID),
                          !appID.contains("*") else { throw unsupported("应用权限标识不匹配") }
                }
                if let value = entitlements["keychain-access-groups"] {
                    guard let groups = value as? [String], let appID = entitlements["application-identifier"] as? String,
                          groups.allSatisfy({ $0 == appID }) else { throw unsupported("不支持共享钥匙串权限") }
                }
                if let value = entitlements["get-task-allow"], !(value is Bool) { throw unsupported("调试权限无效") }
                if let value = entitlements["com.apple.developer.team-identifier"], !(value is String) { throw unsupported("团队权限无效") }
            }
        }
    }

    private func word(_ data: Data, _ offset: Int, big: Bool = false) throws -> UInt32 {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { throw unsupported("主程序数据不完整") }
        let bytes = data[offset..<(offset + 4)]
        return big ? bytes.reduce(0) { ($0 << 8) | UInt32($1) }
            : bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private func unsupported(_ detail: String) -> ProvisioningError { .unsupportedIPA(detail) }
}
