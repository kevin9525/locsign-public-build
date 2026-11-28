import Foundation
import ZIPFoundation

struct ProvisioningExtension: Sendable, Equatable {
    let bundleID: String
    let name: String
}

struct ProvisioningApp: Sendable, Equatable {
    let bundleID: String
    let name: String
    /// App extensions in `PlugIns`, sorted by bundle identifier. Each needs its
    /// own App ID and profile; a free account registers at most 10 App IDs a week.
    var extensions: [ProvisioningExtension] = []
}

struct ProvisioningIPAPreflight: Sendable {
    /// Main app plus extensions must fit the free account's weekly App ID quota.
    static let maximumExtensions = 9
    private static let identifierPattern = #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#

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
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(""), !entry.path.contains("\\"), !entry.path.contains("\0"),
                  !components.contains(".."), !components.contains("."), entry.type != .symlink,
                  !entry.path.hasSuffix("/") || entry.type == .directory,
                  paths.insert(path.lowercased()).inserted,
                  paths.count <= 50_000, entry.uncompressedSize <= 2_147_483_648,
                  total <= 2_147_483_648 - entry.uncompressedSize else { throw unsupported("归档结构或大小不受支持") }
            total += entry.uncompressedSize
        }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try unpack(archive, into: unpacked)
        let payload = unpacked.appendingPathComponent("Payload", isDirectory: true)
        let mainApps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard mainApps.count == 1, let app = mainApps.first,
              let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw unsupported("只支持一个主 App")
        }
        var extensionDirectories: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw unsupported("暂不支持符号链接")
            }
            let kind = url.pathExtension.lowercased()
            // Levels are relative to the main app: PlugIns is level 1, an
            // extension directly inside it level 2. Anything nested deeper
            // (an extension's own PlugIns, Watch apps, ExtensionKit) is rejected.
            if kind == "app" { throw unsupported("暂不支持嵌套 App（如 Apple Watch App）") }
            if kind == "appex" {
                guard enumerator.level == 2, url.deletingLastPathComponent().lastPathComponent == "PlugIns" else {
                    throw unsupported("只支持主 App 的 PlugIns 目录中的扩展，不支持嵌套扩展")
                }
                extensionDirectories.append(url)
            } else if url.lastPathComponent.lowercased() == "plugins",
                      !(enumerator.level == 1 && url.lastPathComponent == "PlugIns") {
                throw unsupported("只支持主 App 的 PlugIns 目录中的扩展，不支持嵌套扩展")
            }
        }
        let infoData = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard infoData.count <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String,
              bundle.range(of: Self.identifierPattern, options: .regularExpression) != nil,
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = Self.executableName(info) else { throw unsupported("应用信息不完整") }
        let binary = app.appendingPathComponent(executable)
        guard try binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw unsupported("缺少主程序")
        }
        try inspectMachO(Data(contentsOf: binary, options: .mappedIfSafe), bundleID: bundle)
        guard extensionDirectories.count <= Self.maximumExtensions else {
            throw unsupported("扩展超过 \(Self.maximumExtensions) 个；免费账号每周最多注册 10 个应用标识")
        }
        var extensions: [ProvisioningExtension] = []
        for directory in extensionDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            extensions.append(try inspectExtension(directory, parent: bundle))
        }
        guard Set(extensions.map { $0.bundleID.lowercased() }).count == extensions.count else {
            throw unsupported("多个扩展使用了相同的应用标识")
        }
        try Task.checkCancellation()
        return ProvisioningApp(bundleID: bundle,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent,
            extensions: extensions.sorted { $0.bundleID < $1.bundleID })
    }

    /// Enforce limits against actual inflated bytes, not just ZIP headers.
    /// This workspace is read only by preflight, so executable modes are not
    /// needed. The caller removes the entire workspace on every exit path.
    private func unpack(_ archive: Archive, into directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL.path + "/"
        var total: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(root), entry.type != .symlink else {
                throw unsupported("归档路径不受支持")
            }
            if entry.type == .directory {
                guard entry.uncompressedSize == 0 else { throw unsupported("归档目录大小无效") }
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: destination.path),
                  fm.createFile(atPath: destination.path, contents: nil) else {
                throw unsupported("归档文件路径冲突")
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var actual: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 65_536) { chunk in
                try Task.checkCancellation()
                let count = UInt64(chunk.count)
                guard actual <= entry.uncompressedSize, count <= entry.uncompressedSize - actual,
                      count <= 2_147_483_648 - total else {
                    throw unsupported("归档实际展开大小超过声明或限制")
                }
                actual += count
                total += count
                try handle.write(contentsOf: chunk)
            }
            guard actual == entry.uncompressedSize, checksum == entry.checksum else {
                throw unsupported("归档文件大小或校验和不匹配")
            }
        }
        try Task.checkCancellation()
    }

    /// An extension is checked exactly like the main executable: same Mach-O
    /// and entitlement limits, plus an identifier inside the parent's namespace
    /// as iOS requires for installation.
    private func inspectExtension(_ directory: URL, parent: String) throws -> ProvisioningExtension {
        let infoURL = directory.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL), infoData.count <= 1024 * 1024,
              let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil)) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String,
              bundle.range(of: Self.identifierPattern, options: .regularExpression) != nil,
              bundle.hasPrefix(parent + "."),
              info["CFBundlePackageType"] as? String == "XPC!",
              let executable = Self.executableName(info) else {
            throw unsupported("扩展信息不完整，或扩展标识不属于主 App（\(directory.lastPathComponent)）")
        }
        let binary = directory.appendingPathComponent(executable)
        guard try binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw unsupported("扩展缺少主程序（\(directory.lastPathComponent)）")
        }
        do { try inspectMachO(Data(contentsOf: binary, options: .mappedIfSafe), bundleID: bundle) }
        catch ProvisioningError.unsupportedIPA(let detail) {
            throw unsupported("扩展 \(directory.lastPathComponent)：\(detail)")
        }
        return ProvisioningExtension(bundleID: bundle,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? directory.deletingPathExtension().lastPathComponent)
    }

    private static func executableName(_ info: [String: Any]) -> String? {
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("/"),
              !executable.contains("\\"), !executable.contains("\0") else { return nil }
        return executable
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

    private func inspectSignature(_ allocation: Data, bundleID: String) throws {
        let logicalLength = Int(try word(allocation, 4, big: true))
        guard try word(allocation, 0, big: true) == 0xfade0cc0,
              logicalLength >= 12, logicalLength <= allocation.count else { throw unsupported("代码签名容器无效") }
        // LC_CODE_SIGNATURE can reserve padding after the SuperBlob. All index
        // and child bounds must use the declared container, not that allocation.
        let data = Data(allocation.prefix(logicalLength))
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
