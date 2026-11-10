import XCTest
@testable import LocSign

final class AppRenewalPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func testDueBoundaryRetryAndSelfExclusion() {
        var app = row()
        app.profileExpiry = now.addingTimeInterval(48 * 3600 + 1)
        XCTAssertFalse(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
        app.profileExpiry = now.addingTimeInterval(48 * 3600)
        XCTAssertTrue(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
        app.nextAttempt = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
        XCTAssertTrue(AppRenewalPolicy.due(app, now: app.nextAttempt!, runningBundleID: nil))
        XCTAssertFalse(AppRenewalPolicy.due(app, now: app.nextAttempt!, runningBundleID: app.identity.signingBundleID))
    }
    func testOptOutUnconfirmedAndEarlierCertificateExpiry() {
        var app = row()
        app.profileExpiry = now.addingTimeInterval(7 * 86400)
        app.certificateExpiry = now.addingTimeInterval(3600)
        XCTAssertTrue(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
        app.autoRenew = false
        XCTAssertFalse(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
        app.autoRenew = true
        app.installedAt = nil
        XCTAssertFalse(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
    }
    func testMinimumExpiryCannotReuseOldProfile() {
        var app = row()
        app.profileExpiry = now.addingTimeInterval(7 * 86400)
        XCTAssertEqual(AppRenewalPolicy.minimumExpiry(app, now: now), app.profileExpiry)
        app.profileExpiry = now.addingTimeInterval(-86400)
        XCTAssertEqual(AppRenewalPolicy.minimumExpiry(app, now: now), now.addingTimeInterval(48 * 3600))
    }
    private func row() -> ManagedApp {
        var result = ManagedApp(id: UUID(), name: "Demo", identity: .init(appleID: "test@example.com", teamID: "TEAM",
            deviceUDID: "DEVICE", originalBundleID: "org.example.demo", signingBundleID: "org.example.demo"))
        result.sourceFile = UUID().uuidString + ".ipa"
        result.installedAt = now.addingTimeInterval(-86400)
        result.profileExpiry = now
        result.certificateExpiry = now.addingTimeInterval(30 * 86400)
        return result
    }
}
