import Foundation
import Combine

/// Shared between installation and diagnostics. Pairing credentials stay in a
/// protected, backup-excluded Application Support file, never UserDefaults.
@MainActor
final class InstallationSettings: ObservableObject {
    struct SavedPairing: Codable, Equatable {
        let data: Data
        let name: String
    }
    struct SigningChoice: Codable {
        let personal: Bool
        let identifier: String
    }
    @Published private(set) var pairing: SavedPairing?
    @Published private(set) var loadError: String?
    @Published private(set) var operationID: UUID?
    @Published private(set) var host: String
    let defaults: UserDefaults
    private let directory: URL
    private var pairingURL: URL { directory.appendingPathComponent("pairing.json") }

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        host = defaults.string(forKey: "install.host") ?? "10.7.0.1"
        reloadPairing()
    }

    func reloadPairing() {
        guard operationID == nil else { return }
        do {
            if FileManager.default.fileExists(atPath: pairingURL.path) {
                let saved = try JSONDecoder().decode(SavedPairing.self, from: Data(contentsOf: pairingURL))
                _ = try PairingRecord(data: saved.data)
                if pairing != saved { pairing = saved }
            } else if pairing != nil { pairing = nil }
            loadError = nil
        } catch { loadError = "读取已保存配对文件失败，请解锁手机或重新导入：\(error.localizedDescription)" }
    }

    static func live() -> InstallationSettings {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return InstallationSettings(directory: root.appendingPathComponent("Installation", isDirectory: true))
    }

    func updateHost(_ value: String) {
        guard operationID == nil, host != value else { return }
        host = value
        defaults.set(value, forKey: "install.host")
    }

    func savePairing(data: Data, name: String) throws {
        guard operationID == nil else { throw LocSignError.install("请等待当前设备操作完成") }
        guard data.count <= 10_485_760 else { throw LocSignError.install("配对文件超过 10 MB") }
        _ = try PairingRecord(data: data)
        let saved = SavedPairing(data: data, name: name)
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
        try JSONEncoder().encode(saved).write(to: pairingURL, options: [.atomic, .completeFileProtection])
        pairing = saved
        loadError = nil
    }

    func clearPairing() throws {
        guard operationID == nil else { throw LocSignError.install("请等待当前设备操作完成") }
        if FileManager.default.fileExists(atPath: pairingURL.path) { try FileManager.default.removeItem(at: pairingURL) }
        pairing = nil
        loadError = nil
    }

    func beginOperation() -> UUID? {
        guard operationID == nil else { return nil }
        let id = UUID()
        operationID = id
        return id
    }
    func endOperation(_ id: UUID) { if operationID == id { operationID = nil } }

    func signingChoice(bundleID: String, teamID: String) -> SigningChoice? {
        guard let data = defaults.data(forKey: choiceKey(bundleID, teamID)) else { return nil }
        return try? JSONDecoder().decode(SigningChoice.self, from: data)
    }
    func saveSigningChoice(_ choice: SigningChoice, bundleID: String, teamID: String) throws {
        if choice.personal { _ = try ProvisioningSigningIdentifier.validate(choice.identifier) }
        defaults.set(try JSONEncoder().encode(choice), forKey: choiceKey(bundleID, teamID))
    }
    private func choiceKey(_ bundle: String, _ team: String) -> String {
        "install.identifier." + Data(team.utf8).base64EncodedString() + "." + Data(bundle.utf8).base64EncodedString()
    }
}
