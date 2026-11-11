import Foundation

/// An explicit workaround for device endpoints that reject connections on cellular.
/// A Shortcut callback and a successful QueryType are separate required steps.
@MainActor
final class LocationNetworkAssist {
    enum Action: String { case disable, enable }
    private static let restoreKey = "location.networkAssist.requiresRestore"
    var onChange: (() -> Void)?
    private(set) var status: String?
    private(set) var restoreWarning: String?
    var requiresRestore: Bool { defaults.bool(forKey: Self.restoreKey) }
    private let defaults: UserDefaults
    private let runShortcut: (Action) async throws -> Void
    private let probe: (String, TimeInterval) async throws -> Void
    private let pause: () async throws -> Void
    private let now: () -> TimeInterval
    private let readinessTimeout: TimeInterval
    private var busy = false

    init(defaults: UserDefaults,
         runShortcut: @escaping (Action) async throws -> Void,
         probe: @escaping (String, TimeInterval) async throws -> Void,
         pause: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 300_000_000) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readinessTimeout: TimeInterval = 15) {
        self.defaults = defaults; self.runShortcut = runShortcut; self.probe = probe
        self.pause = pause; self.now = now; self.readinessTimeout = readinessTimeout
    }

    func run(host: String, operation: () async throws -> Void) async throws {
        guard !busy, !requiresRestore else {
            throw LocationControlError.message("上次蜂窝数据恢复尚未确认，请先点“恢复蜂窝数据”。")
        }
        try Task.checkCancellation()
        busy = true
        defer { busy = false; status = nil; onChange?() }
        // Persist before leaving the app, including termination during the shortcut.
        defaults.set(true, forKey: Self.restoreKey)
        restoreWarning = nil
        do {
            update("等待快捷指令关闭蜂窝数据并返回 LocSign…")
            try await runShortcut(.disable)
            try Task.checkCancellation()
            update("正在等待本地设备服务就绪…")
            try await waitForEndpoint(host)
            try Task.checkCancellation()
            update("设备服务可达，正在认证并执行定位…")
            try await operation()
        } catch {
            if let failure = error as? LocationShortcutRunner.Failure, case .completionUnknown = failure {
                // A timed-out shortcut can still execute later. Do not race it by
                // running enable and claiming recovery; require the user to stop it.
                restoreWarning = "关闭数据指令状态未知。请先在“快捷指令”App 中停止仍在运行的指令，再点“恢复蜂窝数据”。"
                onChange?()
                throw error
            }
            await attemptRestore()
            throw error
        }
        await attemptRestore()
    }

    func restoreData() async {
        guard !busy, requiresRestore else { return }
        busy = true
        defer { busy = false; status = nil; onChange?() }
        await attemptRestore()
    }

    private func waitForEndpoint(_ host: String) async throws {
        let deadline = now() + readinessTimeout
        while now() < deadline {
            try Task.checkCancellation()
            do {
                try await probe(host, min(1, deadline - now()))
                try Task.checkCancellation()
                return
            } catch is CancellationError { throw CancellationError() }
            catch { /* Network transitions can briefly refuse or time out. */ }
            try await pause()
        }
        throw LocationControlError.message("关闭蜂窝数据后，设备服务仍未就绪。请确认 LocalDevVPN 保持连接；此系统暂未通过无 Wi-Fi 连接验证，可连接 Wi-Fi 后使用。")
    }

    private func attemptRestore() async {
        update("等待快捷指令恢复蜂窝数据并返回 LocSign…")
        // Restoration must still run when the location operation was cancelled.
        let restore = Task { @MainActor in try await runShortcut(.enable) }
        do {
            try await restore.value
            defaults.set(false, forKey: Self.restoreKey)
            restoreWarning = nil
        } catch {
            restoreWarning = "蜂窝数据恢复未确认。请点“恢复蜂窝数据”，或在系统设置中开启蜂窝数据。"
        }
        onChange?()
    }

    private func update(_ message: String) { status = message; onChange?() }
}
