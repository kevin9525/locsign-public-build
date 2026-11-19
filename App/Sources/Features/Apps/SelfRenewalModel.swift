import Foundation
import Combine
import UserNotifications

/// Describes the installed profile, not a guarantee that its certificate has not
/// been revoked. This reader never substitutes an assumed seven-day lifetime.
struct InstalledSelfProfile: Equatable, Identifiable, Sendable {
    let bundleID: String
    let teamID: String
    let profileExpiry: Date
    var deviceUDIDs: [String] = []
    var id: String { bundleID }

    static func read(data: Data, bundleID: String, trustAnchors: [Data], now: Date) throws -> Self {
        guard let content = LocSignVerifyProvisioningCMS(data, trustAnchors, now),
              let payload = try PlistCodec.decode(content) as? [String: Any],
              let teams = payload["TeamIdentifier"] as? [String], teams.count == 1, !teams[0].isEmpty,
              let expiry = payload["ExpirationDate"] as? Date,
              let creation = payload["CreationDate"] as? Date, creation <= now, expiry > creation,
              expiry.timeIntervalSince1970.isFinite else { throw ProfileValidationError.metadata }
        let profile = ProvisioningProfileData(raw: data, payload: payload)
        guard !bundleID.isEmpty, profile.permits(bundleIdentifier: bundleID) else { throw ProfileValidationError.metadata }
        return .init(bundleID: bundleID, teamID: teams[0], profileExpiry: expiry, deviceUDIDs: profile.deviceUDIDs)
    }

    static func current() throws -> Self {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            throw LocSignError.install("未找到当前安装的描述文件，无法确认到期时间。")
        }
        let now = Date()
        return try read(data: Data(contentsOf: url), bundleID: bundleID,
                        trustAnchors: ProvisioningProfileValidator.apple(now: now).trustAnchors, now: now)
    }
}

struct SelfRenewalReminder: Equatable, Sendable {
    static let identifiers = ["locsign.self-expiry.48h", "locsign.self-expiry.24h"]
    let id: String
    let date: Date
    let hours: Int

    static func plan(expiry: Date, now: Date) -> [Self] {
        guard expiry.timeIntervalSince1970.isFinite else { return [] }
        return zip(identifiers, [48, 24]).compactMap { id, hours in
            let date = expiry.addingTimeInterval(-Double(hours) * 3600)
            return date > now ? .init(id: id, date: date, hours: hours) : nil
        }
    }
}

@MainActor
protocol SelfRenewalNotificationCenter {
    func requestPermission() async -> Bool
    func isAuthorized() async -> Bool
    func removePending(_ identifiers: [String])
    func add(_ reminder: SelfRenewalReminder) async throws
}

@MainActor
private final class SystemSelfRenewalNotifications: SelfRenewalNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func add(_ reminder: SelfRenewalReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = "LocSign 即将到期"
        content.body = "描述文件将在约 \(reminder.hours) 小时后到期。请打开 LocSign 的 App 页，手动续签自身。"
        content.sound = .default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(.init(identifier: reminder.id, content: content, trigger: trigger))
    }
}

@MainActor
final class SelfRenewalModel: ObservableObject {
    @Published private(set) var profile: InstalledSelfProfile?
    @Published private(set) var profileError: String?
    @Published private(set) var notificationError: String?
    @Published private(set) var remindersEnabled: Bool
    private let defaults: UserDefaults
    private let notifications: any SelfRenewalNotificationCenter
    private let readProfile: () throws -> InstalledSelfProfile
    private let now: () -> Date
    private var permissionRevision = UUID()
    private var notificationUpdate: Task<Void, Never>?

    init(defaults: UserDefaults, notifications: (any SelfRenewalNotificationCenter)? = nil,
         now: @escaping () -> Date = Date.init,
         readProfile: @escaping () throws -> InstalledSelfProfile = InstalledSelfProfile.current) {
        self.defaults = defaults
        self.notifications = notifications ?? SystemSelfRenewalNotifications()
        self.readProfile = readProfile; self.now = now
        remindersEnabled = defaults.bool(forKey: "selfRenewal.remindersEnabled")
    }

    func refresh() async {
        do { profile = try readProfile(); profileError = nil }
        catch { profile = nil; profileError = "无法确认当前描述文件到期时间：" + error.localizedDescription }
        await synchronizeNotifications()
    }

    func setRemindersEnabled(_ enabled: Bool) async {
        permissionRevision = UUID()
        let revision = permissionRevision
        notificationError = nil
        if enabled {
            let allowed = await notifications.requestPermission()
            guard permissionRevision == revision else { return }
            remindersEnabled = allowed
            if !allowed { notificationError = "通知未获允许，请在 iOS 设置中开启 LocSign 通知。" }
        } else { remindersEnabled = false }
        defaults.set(remindersEnabled, forKey: "selfRenewal.remindersEnabled")
        await synchronizeNotifications()
    }

    private func synchronizeNotifications() async {
        // Serialize updates across awaits: a late add from an older refresh must
        // not recreate reminders after the user has disabled them.
        let previous = notificationUpdate
        let update = Task { @MainActor [self] in
            await previous?.value
            notifications.removePending(SelfRenewalReminder.identifiers)
            guard remindersEnabled, let profile else { return }
            guard await notifications.isAuthorized() else {
                notificationError = "通知权限已关闭，请在 iOS 设置中开启 LocSign 通知。"
                return
            }
            do {
                for reminder in SelfRenewalReminder.plan(expiry: profile.profileExpiry, now: now()) {
                    try await notifications.add(reminder)
                }
                notificationError = nil
            } catch { notificationError = "未能安排到期提醒，请重试或设置日历提醒。" }
        }
        notificationUpdate = update
        await update.value
    }
}
