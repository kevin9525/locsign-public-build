import Foundation
import Combine
import CryptoKit

struct ManagedApp: Codable, Identifiable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let appleID: String
        let teamID: String
        let deviceUDID: String
        let originalBundleID: String
        let signingBundleID: String
    }
    struct Pending: Codable, Equatable, Sendable {
        let sourceFile: String
        let profileExpiry: Date
        let certificateExpiry: Date
        let profileSHA256: String
        let attemptedLaunchID: UUID
        let replacesCurrentProfile: Bool
    }
    let id: UUID
    var name: String
    let identity: Identity
    var sourceFile: String?
    var installedAt: Date?
    var profileExpiry: Date?
    var certificateExpiry: Date?
    var pending: Pending?
    var autoRenew = true
    var nextAttempt: Date?
    var lastAttempt: Date?
    var lastError: String?
    var effectiveExpiry: Date? {
        guard let profileExpiry, let certificateExpiry else { return nil }
        return min(profileExpiry, certificateExpiry)
    }
}

/// The manifest never contains credentials. Files are immutable until the new
/// manifest is committed; failed writes cannot delete the last usable source.
@MainActor
final class ManagedAppLibrary: ObservableObject {
    @Published private(set) var apps: [ManagedApp] = []
    @Published private(set) var loadError: String?
    private struct Manifest: Codable { let version: Int; let apps: [ManagedApp] }
    private let directory: URL
    private let launchID: UUID
    private let runningBundleID: String?
    private let currentProfileSHA256: String?
    private var manifestURL: URL { directory.appendingPathComponent("apps.json") }

    init(directory: URL, launchID: UUID = UUID(), runningBundleID: String? = nil, currentProfile: Data? = nil) {
        self.directory = directory; self.launchID = launchID
        self.runningBundleID = runningBundleID
        self.currentProfileSHA256 = currentProfile.map(Self.digest)
        reload()
    }
    static func live() -> ManagedAppLibrary {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        return ManagedAppLibrary(directory: root.appendingPathComponent("Apps", isDirectory: true),
            runningBundleID: Bundle.main.bundleIdentifier, currentProfile: profile)
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let data = try Data(contentsOf: manifestURL)
                guard data.count <= 10_485_760 else { throw failure("应用记录过大") }
                let saved = try JSONDecoder().decode(Manifest.self, from: data)
                guard saved.version == 1, saved.apps.count <= 1000, Set(saved.apps.map(\.id)).count == saved.apps.count,
                      saved.apps.allSatisfy({ row in
                          [row.sourceFile, row.pending?.sourceFile].compactMap { $0 }.allSatisfy(Self.validFilename)
                      }) else { throw failure("应用记录格式无效") }
                apps = saved.apps
            } else { apps = [] }
            loadError = nil
        } catch { loadError = "读取应用记录失败，请解锁手机后重试：" + error.localizedDescription }
    }

    func prepare(source: URL, name: String, identity: ManagedApp.Identity, material: ProvisioningMaterial) async throws -> UUID {
        try writable()
        guard source.isFileURL, !identity.appleID.isEmpty, !identity.teamID.isEmpty, !identity.deviceUDID.isEmpty else {
            throw failure("缺少应用续签身份")
        }
        _ = try ProvisioningSigningIdentifier.validate(identity.originalBundleID)
        _ = try ProvisioningSigningIdentifier.validate(identity.signingBundleID)
        try makeDirectory()
        let filename = UUID().uuidString + ".ipa"
        let destination = directory.appendingPathComponent(filename)
        let copy = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 2_147_483_648 else {
                throw LocSignError.install("无法保存原 IPA：文件为空或超过 2 GB")
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            try Task.checkCancellation()
        }
        do {
            try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
            try Task.checkCancellation()
            try writable()
            var rows = apps
            let index: Int
            if let existing = rows.firstIndex(where: { $0.identity == identity }) { index = existing }
            else {
                guard rows.count < 1000 else { throw failure("应用记录已达上限，请清除不用的记录") }
                rows.append(.init(id: UUID(), name: name, identity: identity))
                index = rows.count - 1
            }
            rows[index].name = String(name.prefix(256))
            rows[index].pending = .init(sourceFile: filename, profileExpiry: material.profileExpiry,
                certificateExpiry: material.certificateExpiry, profileSHA256: Self.digest(material.profileData),
                attemptedLaunchID: launchID,
                replacesCurrentProfile: identity.signingBundleID == runningBundleID && currentProfileSHA256 != nil && Self.digest(material.profileData) != currentProfileSHA256)
            rows[index].lastError = nil
            try commit(rows)
            return rows[index].id
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func confirmInstallation(id: UUID, now: Date = Date()) throws {
        guard let index = apps.firstIndex(where: { $0.id == id }), let pending = apps[index].pending else {
            throw failure("未找到待确认的安装记录")
        }
        var rows = apps
        rows[index].sourceFile = pending.sourceFile
        rows[index].profileExpiry = pending.profileExpiry
        rows[index].certificateExpiry = pending.certificateExpiry
        rows[index].installedAt = now
        rows[index].pending = nil
        rows[index].lastError = nil
        rows[index].nextAttempt = nil
        let identity = rows[index].identity
        // A manual installation under a new team/account supersedes the old
        // record only after the device has confirmed the replacement.
        rows.removeAll { $0.id != id && $0.identity.deviceUDID == identity.deviceUDID && $0.identity.signingBundleID == identity.signingBundleID }
        try commit(rows)
    }

    func fail(id: UUID, message: String, preservePending: Bool = false) throws {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        var rows = apps
        if rows[index].installedAt != nil && !preservePending { rows[index].pending = nil }
        // Self replacement can terminate the client before a response arrives.
        rows[index].lastError = String(ProvisioningRedaction.redact(message).prefix(1500))
        try commit(rows)
    }

    func recordAttempt(id: UUID, now: Date) throws {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { throw failure("应用记录不存在") }
        var rows = apps
        rows[index].lastAttempt = now
        rows[index].nextAttempt = now.addingTimeInterval(AppRenewalPolicy.retryInterval)
        try commit(rows)
    }
    func setAutoRenew(id: UUID, enabled: Bool) throws {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        var rows = apps; rows[index].autoRenew = enabled
        try commit(rows)
    }
    func remove(id: UUID) throws { try commit(apps.filter { $0.id != id }) }

    func sourceURL(for id: UUID) throws -> URL {
        guard let app = apps.first(where: { $0.id == id }),
              let filename = app.sourceFile ?? app.pending?.sourceFile, Self.validFilename(filename) else {
            throw failure("没有保存原 IPA，请重新选择原 IPA 安装一次")
        }
        let url = directory.appendingPathComponent(filename)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("保存的原 IPA 不可用，请重新导入") }
        return url
    }

    func reconcileSelf(bundleID: String, embeddedProfile: Data) throws {
        let hash = Self.digest(embeddedProfile)
        for app in apps where app.identity.signingBundleID == bundleID && app.pending?.profileSHA256 == hash
            && app.pending?.attemptedLaunchID != launchID && app.pending?.replacesCurrentProfile == true {
            try confirmInstallation(id: app.id)
        }
    }

    func recoverInterrupted(runningBundleID: String?) throws {
        var rows = apps
        var changed = false
        for index in rows.indices where rows[index].pending != nil && rows[index].identity.signingBundleID != runningBundleID {
            if rows[index].installedAt != nil { rows[index].pending = nil }
            rows[index].lastError = "上次安装未确认完成，请手动续签确认"
            changed = true
        }
        if changed { try commit(rows) }
    }

    private func commit(_ rows: [ManagedApp]) throws {
        try writable()
        try makeDirectory()
        try JSONEncoder().encode(Manifest(version: 1, apps: rows)).write(to: manifestURL, options: [.atomic, .completeFileProtection])
        let oldFiles = Set(apps.flatMap { [$0.sourceFile, $0.pending?.sourceFile].compactMap { $0 } })
        let retained = Set(rows.flatMap { [$0.sourceFile, $0.pending?.sourceFile].compactMap { $0 } })
        apps = rows
        for filename in oldFiles.subtracting(retained) where Self.validFilename(filename) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        }
    }
    private func writable() throws { if let loadError { throw failure(loadError) } }
    private func makeDirectory() throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    private static func validFilename(_ name: String) -> Bool {
        name.hasSuffix(".ipa") && UUID(uuidString: String(name.dropLast(4))) != nil
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ message: String) -> LocSignError { .install(message) }
}
