import Foundation
import CoreFoundation

struct InstalledApp: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let version: String
}

struct InstalledAppList: Sendable {
    let deviceUDID: String
    let apps: [InstalledApp]
}

protocol InstalledAppListing {
    func listApps(host: String, pairingData: Data) async throws -> InstalledAppList
}

/// A read-only device session. No AFC connection or installation command is used.
final class InstalledAppBrowser: InstalledAppListing {
    private let makeTransport: (String) async throws -> any LockdownTransport
    private let openService: (String, LockdownServiceEndpoint, PairingRecord) async throws -> any DeviceServiceTransport
    private static let maximumRows = 10_000
    private static let maximumPages = 1_024

    init(makeTransport: @escaping (String) async throws -> any LockdownTransport = {
        try await LockdownNetworkTransport(host: $0)
    }, openService: @escaping (String, LockdownServiceEndpoint, PairingRecord) async throws -> any DeviceServiceTransport = {
        try await DeviceServiceConnection(host: $0, endpoint: $1, pairing: $2)
    }) {
        self.makeTransport = makeTransport
        self.openService = openService
    }

    func listApps(host: String, pairingData: Data) async throws -> InstalledAppList {
        let connections = BrowseConnectionLifetime()
        return try await withTaskCancellationHandler {
            var heartbeat: DeviceHeartbeat?
            do {
                try Task.checkCancellation()
                let pairing = try PairingRecord(data: pairingData)
                let transport = BrowseLockdownConnection(try await makeTransport(host))
                connections.own { transport.close() }
                try Task.checkCancellation()
                let session = LockdownSession(transport: transport, pairing: pairing)
                try await session.start()
                try Task.checkCancellation()
                let deviceUDID = try await session.queryUniqueDeviceID()
                try Task.checkCancellation()

                let heartbeatEndpoint = try await session.startService("com.apple.mobile.heartbeat")
                try Task.checkCancellation()
                let heartbeatConnection = BrowseServiceConnection(try await openService(host, heartbeatEndpoint, pairing))
                connections.own { heartbeatConnection.close() }
                try Task.checkCancellation()
                let activeHeartbeat = DeviceHeartbeat(connection: heartbeatConnection)
                heartbeat = activeHeartbeat
                try await activeHeartbeat.start()
                try activeHeartbeat.check()

                let endpoint = try await session.startService("com.apple.mobile.installation_proxy")
                try activeHeartbeat.check()
                let connection = BrowseServiceConnection(try await openService(host, endpoint, pairing))
                connections.own { connection.close() }
                try activeHeartbeat.check()

                let apps = try await Self.browse(connection: connection, heartbeat: activeHeartbeat)
                try activeHeartbeat.check()
                await activeHeartbeat.stop()
                connections.close()
                try Task.checkCancellation()
                return InstalledAppList(deviceUDID: deviceUDID, apps: apps)
            } catch {
                connections.close()
                await heartbeat?.stop()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let cause = error as NSError
                if cause.domain == "LocSign.AppBrowse" { throw error }
                throw NSError(domain: "LocSign.AppBrowse", code: cause.code, userInfo: [
                    NSLocalizedDescriptionKey: "读取设备 App 失败：\(cause.localizedDescription)",
                    NSUnderlyingErrorKey: cause
                ])
            }
        } onCancel: {
            // Interrupt existing socket reads, including the lockdown handshake.
            // A connection opened after cancellation is closed as soon as owned.
            connections.close()
        }
    }

    private static func browse(connection: any DeviceServiceTransport, heartbeat: DeviceHeartbeat) async throws -> [InstalledApp] {
        try heartbeat.check()
        try await connection.sendPlist([
            "Command": "Browse",
            "ClientOptions": [
                "ApplicationType": "User",
                "ReturnAttributes": ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
                                     "CFBundleShortVersionString", "CFBundleVersion", "ApplicationType"]
            ]
        ])
        var apps: [InstalledApp] = []
        var identifiers: Set<String> = []
        for _ in 0..<maximumPages {
            try heartbeat.check()
            let response = try await connection.receivePlist()
            try heartbeat.check()
            if let error = response["Error"] {
                guard let code = error as? String, !code.isEmpty else {
                    throw invalid("设备返回无效的 App 查询错误")
                }
                throw invalid("设备拒绝读取 App 清单（\(code.prefix(256))）")
            }
            guard let status = response["Status"] as? String,
                  status == "BrowsingApplications" || status == "Complete" else {
                throw invalid("设备返回无效的 App 查询状态")
            }

            if let currentList = response["CurrentList"] {
                guard let rows = currentList as? [[String: Any]],
                      let index = counter(response["CurrentIndex"]),
                      let amount = counter(response["CurrentAmount"]),
                      index == apps.count, amount == rows.count,
                      rows.count <= maximumRows - apps.count else {
                    throw invalid("设备 App 清单分页无效或数量超出限制")
                }
                for row in rows {
                    try Task.checkCancellation()
                    let app = try parse(row)
                    // Browse is a single ordered stream, not a retrying request.
                    // Repeated identifiers, even identical rows, cannot establish
                    // a complete snapshot and are rejected rather than hidden.
                    guard identifiers.insert(app.id).inserted else {
                        throw invalid("设备 App 清单包含重复的应用标识")
                    }
                    apps.append(app)
                }
            } else {
                guard status == "Complete", response["CurrentIndex"] == nil,
                      response["CurrentAmount"] == nil else {
                    throw invalid("设备 App 清单缺少分页内容")
                }
            }
            if status == "Complete" { return apps }
        }
        throw invalid("设备 App 清单分页次数超出限制")
    }

    private static func counter(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let numeric = number.doubleValue
        guard numeric.isFinite, numeric >= 0, numeric <= Double(maximumRows),
              numeric.rounded(.towardZero) == numeric else { return nil }
        return Int(numeric)
    }

    private static func parse(_ row: [String: Any]) throws -> InstalledApp {
        guard let identifier = try string(row, key: "CFBundleIdentifier", maximumBytes: 255),
              !identifier.contains(where: { $0.isWhitespace }) else {
            throw invalid("设备 App 清单包含无效的应用标识")
        }
        let displayName = try string(row, key: "CFBundleDisplayName", maximumBytes: 1024)
        let bundleName = try string(row, key: "CFBundleName", maximumBytes: 1024)
        let shortVersion = try string(row, key: "CFBundleShortVersionString", maximumBytes: 256)
        let bundleVersion = try string(row, key: "CFBundleVersion", maximumBytes: 256)
        let applicationType = try string(row, key: "ApplicationType", maximumBytes: 32)
        guard row["ApplicationType"] == nil || applicationType == "User" else {
            throw invalid("设备返回了非用户 App")
        }
        return InstalledApp(id: identifier, name: displayName ?? bundleName ?? identifier,
                            version: shortVersion ?? bundleVersion ?? "未知")
    }

    private static func string(_ row: [String: Any], key: String, maximumBytes: Int) throws -> String? {
        guard let raw = row[key] else { return nil }
        guard let value = raw as? String, value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
            throw invalid("设备 App 清单中的 \(key) 无效")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "LocSign.AppBrowse", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "读取设备 App 失败：\(message)"])
    }
}

/// Registration and cancellation are synchronized so an in-flight async open
/// cannot leak a connection after the cancellation handler has already run.
private final class BrowseConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var actions: [() -> Void] = []

    func own(_ close: @escaping () -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            close()
        } else {
            actions.append(close)
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let actions = self.actions.reversed()
        self.actions.removeAll()
        lock.unlock()
        for close in actions { close() }
    }
}

/// Session and heartbeat already close on their own failure paths. These
/// adapters give this operation exactly one underlying close per connection,
/// including races between their cleanup and task cancellation.
private final class BrowseCloseOnce {
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) { self.action = action }

    func close() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

private final class BrowseLockdownConnection: LockdownTransport {
    private let transport: any LockdownTransport
    private let closer: BrowseCloseOnce

    init(_ transport: any LockdownTransport) {
        self.transport = transport
        self.closer = BrowseCloseOnce { transport.close() }
    }

    func send(_ request: [String: Any]) async throws { try await transport.send(request) }
    func receive() async throws -> [String: Any] { try await transport.receive() }
    func upgradeToTLS(using pairing: PairingRecord) async throws { try await transport.upgradeToTLS(using: pairing) }
    func close() { closer.close() }
}

private final class BrowseServiceConnection: DeviceServiceTransport {
    private let transport: any DeviceServiceTransport
    private let closer: BrowseCloseOnce

    init(_ transport: any DeviceServiceTransport) {
        self.transport = transport
        self.closer = BrowseCloseOnce { transport.close() }
    }

    func sendPlist(_ value: [String: Any]) async throws { try await transport.sendPlist(value) }
    func receivePlist() async throws -> [String: Any] { try await transport.receivePlist() }
    func exchangeAFC(_ frame: AFCFrame) async throws -> AFCFrame { try await transport.exchangeAFC(frame) }
    func close() { closer.close() }
}
