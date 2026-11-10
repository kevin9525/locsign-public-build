import Foundation

enum AppRenewalPolicy {
    static let renewalWindow: TimeInterval = 48 * 3600
    static let retryInterval: TimeInterval = 6 * 3600

    static func due(_ app: ManagedApp, now: Date, runningBundleID: String?) -> Bool {
        guard app.autoRenew, app.installedAt != nil, app.sourceFile != nil, app.pending == nil,
              app.identity.signingBundleID != runningBundleID, let expiry = app.effectiveExpiry,
              expiry <= now.addingTimeInterval(renewalWindow), (app.nextAttempt ?? .distantPast) <= now else { return false }
        return true
    }
    static func minimumExpiry(_ app: ManagedApp, now: Date) -> Date {
        max(now.addingTimeInterval(renewalWindow), app.profileExpiry ?? .distantPast)
    }
    static func nextDate(_ app: ManagedApp, now: Date, runningBundleID: String?) -> Date? {
        guard app.autoRenew, app.installedAt != nil, app.sourceFile != nil, app.pending == nil,
              app.identity.signingBundleID != runningBundleID, let expiry = app.effectiveExpiry else { return nil }
        return max(now.addingTimeInterval(15 * 60), max(expiry.addingTimeInterval(-renewalWindow), app.nextAttempt ?? .distantPast))
    }
}
