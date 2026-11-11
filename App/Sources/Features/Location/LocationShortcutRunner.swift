import Foundation
import UIKit

/// Never interpret UIApplication.open's acknowledgement as shortcut completion.
@MainActor
final class LocationShortcutRunner {
    enum Failure: LocalizedError {
        case completionUnknown
        var errorDescription: String? {
            "未收到快捷指令完成回传。请先在“快捷指令”App 中停止仍在运行的关闭数据指令，再返回恢复蜂窝数据。"
        }
    }
    private let openURL: (URL) async -> Bool
    private let waitForTimeout: () async throws -> Void
    private var pending: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var timeout: Task<Void, Never>?

    init(openURL: @escaping (URL) async -> Bool = { await UIApplication.shared.open($0) },
         waitForTimeout: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 90_000_000_000) }) {
        self.openURL = openURL
        self.waitForTimeout = waitForTimeout
    }

    func run(_ action: LocationNetworkAssist.Action) async throws {
        guard pending == nil else { throw LocationControlError.message("请先完成正在运行的快捷指令。") }
        let id = UUID()
        let name = action == .disable ? "LocSign关闭蜂窝数据" : "LocSign开启蜂窝数据"
        var url = URLComponents()
        url.scheme = "shortcuts"; url.host = "x-callback-url"; url.path = "/run-shortcut"
        url.queryItems = [URLQueryItem(name: "name", value: name)] + ["success", "error", "cancel"].map {
            URLQueryItem(name: "x-" + $0, value: "locsign://network-assist/\(id.uuidString)?result=\($0)")
        }
        guard let request = url.url else { throw LocationControlError.message("无法创建快捷指令地址。") }
        // Do not abandon an in-flight disable shortcut on task cancellation: a late
        // disable could otherwise execute AFTER recovery. Bound the callback wait.
        try await withCheckedThrowingContinuation { continuation in
            pending = (id, continuation)
            timeout = Task { [weak self] in
                guard let self else { return }
                do { try await self.waitForTimeout() } catch { return }
                self.finish(id, .failure(Failure.completionUnknown))
            }
            Task { [weak self] in
                guard let self else { return }
                if !(await self.openURL(request)) {
                    self.finish(id, .failure(LocationControlError.message("无法打开快捷指令，请先安装 iOS“快捷指令”App 并完成无 Wi-Fi 辅助设置。")))
                }
            }
        }
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "locsign", url.host == "network-assist",
              url.user == nil, url.password == nil, url.port == nil,
              let id = UUID(uuidString: String(url.path.dropFirst())), id == pending?.id,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let results = query.filter { $0.name == "result" }
        guard results.count == 1, let result = results.first?.value,
              ["success", "error", "cancel"].contains(result) else { return false }
        if result == "success" { finish(id, .success(())) }
        else { finish(id, .failure(LocationControlError.message("快捷指令未完成。请确认名称完全一致、包含“设置蜂窝数据”动作，并允许执行。"))) }
        return true
    }

    private func finish(_ id: UUID, _ result: Result<Void, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        timeout?.cancel(); timeout = nil
        current.continuation.resume(with: result)
    }
}
