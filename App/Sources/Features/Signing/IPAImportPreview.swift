import Foundation
import ZIPFoundation

struct IPAImportPreview: Sendable, Equatable {
    struct Extension: Sendable, Equatable, Identifiable {
        let path: String
        let name: String
        let bundleID: String?
        var id: String { path }
    }
    let name: String
    let bundleID: String?
    let version: String?
    let build: String?
    let minimumOSVersion: String?
    let fileSize: Int64
    let extensions: [Extension]
    let automaticSigningIssue: String?
}

struct IPAImportPreviewInspector: Sendable {
    func inspect(_ url: URL) throws -> IPAImportPreview {
        try Task.checkCancellation()
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw LocSignError.signing("IPA 归档无效，无法读取应用信息") }

        // Read only bounded metadata into memory. Never extract paths from the
        // archive here; the existing preflight owns its own temporary workspace.
        var paths = Set<String>()
        var appRoots = Set<String>()
        var extensionRoots = Set<String>()
        var plists: [String: Entry] = [:]
        var expandedSize: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(""), !parts.contains("."), !parts.contains(".."),
                  !path.contains("\\"), !path.contains("\0"), entry.type != .symlink,
                  !entry.path.hasSuffix("/") || entry.type == .directory,
                  paths.insert(path.lowercased()).inserted, paths.count <= 50_000,
                  entry.uncompressedSize <= 2_147_483_648,
                  expandedSize <= 2_147_483_648 - entry.uncompressedSize else {
                throw LocSignError.signing("IPA 归档路径、结构或大小不符合预览要求")
            }
            expandedSize += entry.uncompressedSize
            guard parts.count >= 2, parts[0] == "Payload", parts[1].lowercased().hasSuffix(".app") else { continue }
            appRoots.insert(parts.prefix(2).joined(separator: "/"))
            if parts.count >= 4, parts[2] == "PlugIns", parts[3].lowercased().hasSuffix(".appex") {
                extensionRoots.insert(parts.prefix(4).joined(separator: "/"))
                if parts.count == 5, parts[4] == "Info.plist" { plists[path] = entry }
            } else if parts.count == 3, parts[2] == "Info.plist" { plists[path] = entry }
        }
        guard appRoots.count == 1, let root = appRoots.first,
              let mainEntry = plists[root + "/Info.plist"] else {
            throw LocSignError.signing("IPA 必须包含一个主 App 和可读取的 Info.plist")
        }
        var metadataSize = 0
        guard let info = try readInfo(mainEntry, archive: archive, total: &metadataSize) else {
            throw LocSignError.signing("主应用 Info.plist 无效")
        }
        var extensions: [IPAImportPreview.Extension] = []
        for path in extensionRoots.sorted() {
            try Task.checkCancellation()
            let extensionInfo: [String: Any]?
            if let entry = plists[path + "/Info.plist"] {
                extensionInfo = try readInfo(entry, archive: archive, total: &metadataSize)
            } else { extensionInfo = nil }
            let values = extensionInfo ?? [:]
            extensions.append(.init(path: path, name: name(values, fallback: path),
                                    bundleID: string(values, "CFBundleIdentifier")))
        }
        let issue: String?
        do {
            _ = try ProvisioningIPAPreflight().inspect(url)
            issue = nil
        } catch is CancellationError { throw CancellationError() }
        catch { issue = ProvisioningRedaction.redact(error.localizedDescription) }
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return IPAImportPreview(name: name(info, fallback: root), bundleID: string(info, "CFBundleIdentifier"),
            version: string(info, "CFBundleShortVersionString"), build: string(info, "CFBundleVersion"),
            minimumOSVersion: string(info, "MinimumOSVersion"), fileSize: Int64(size),
            extensions: extensions, automaticSigningIssue: issue)
    }

    private func readInfo(_ entry: Entry, archive: Archive, total: inout Int) throws -> [String: Any]? {
        let limit = 1_048_576
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit),
              total <= 16 * limit - Int(entry.uncompressedSize) else {
            throw LocSignError.signing("应用信息超过预览限制（单项 1 MB、合计 16 MB）")
        }
        var data = Data()
        let checksum = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard chunk.count <= limit - data.count else { throw LocSignError.signing("应用信息过大") }
            data.append(chunk)
        }
        guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else {
            throw LocSignError.signing("应用信息校验失败，IPA 可能已损坏")
        }
        total += data.count
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func string(_ info: [String: Any], _ key: String) -> String? {
        guard let raw = info[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.utf8.count > 1024 ? nil : value
    }

    private func name(_ info: [String: Any], fallback: String) -> String {
        string(info, "CFBundleDisplayName") ?? string(info, "CFBundleName")
            ?? URL(fileURLWithPath: fallback).deletingPathExtension().lastPathComponent
    }
}
