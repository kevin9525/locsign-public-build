import XCTest
@testable import LocSign

final class AppRenewalStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testStatusBecomesReadyExactlyAtLaterOfWindowAndRetry() {
        var app = row()
        app.profileExpiry = now.addingTimeInterval(49 * 3600)
        XCTAssertEqual(status(app), .waiting(now.addingTimeInterval(3600)))
        app.nextAttempt = now.addingTimeInterval(2 * 3600)
        XCTAssertEqual(status(app), .waiting(now.addingTimeInterval(7200)))
        XCTAssertEqual(status(app, at: now.addingTimeInterval(7200)), .ready)
        XCTAssertTrue(AppRenewalPolicy.due(app, now: now.addingTimeInterval(7200), runningBundleID: nil))
    }

    func testEarlierCertificateExpiryAndPreviousFailureStillAllowDueRetry() {
        var app = row()
        app.profileExpiry = now.addingTimeInterval(7 * 86400)
        app.certificateExpiry = now.addingTimeInterval(3600)
        app.lastError = "Previous failure"
        app.nextAttempt = now
        XCTAssertEqual(status(app), .ready)
        XCTAssertTrue(AppRenewalPolicy.due(app, now: now, runningBundleID: nil))
    }

    func testGlobalAndPerAppOptOutExplainWhyAutomaticRenewalWillNotRun() {
        var app = row()
        XCTAssertEqual(status(app, enabled: false), .globallyDisabled)
        app.autoRenew = false
        XCTAssertEqual(status(app), .appDisabled)
    }

    func testMissingSourceFileAndUnknownExpiryCannotSuggestReady() {
        var app = row()
        XCTAssertEqual(status(app, sourceAvailable: false), .missingSource)
        app.sourceFile = nil
        XCTAssertEqual(status(app), .missingSource)
        app = row()
        app.certificateExpiry = nil
        XCTAssertEqual(status(app), .unknownExpiry)
    }

    func testPendingInstallationTakesPriorityOverTimeAndSwitches() {
        var app = row()
        app.pending = .init(sourceFile: "pending.ipa", profileExpiry: now, certificateExpiry: now,
            profileSHA256: "synthetic", attemptedLaunchID: UUID(), replacesCurrentProfile: false)
        XCTAssertEqual(status(app, enabled: false), .pendingInstallation)
        app.pending?.awaitingRelaunchVerification = true
        XCTAssertEqual(status(app), .pendingSelfVerification)
    }

    func testUnconfirmedInstallAndSelfAreNotAdvertisedAsAutomatic() {
        var app = row()
        app.installedAt = nil
        XCTAssertEqual(status(app), .notInstalled)
        app = row()
        XCTAssertEqual(AppRenewalStatus.evaluate(app, enabled: true, sourceAvailable: true,
            runningBundleID: app.identity.signingBundleID, now: now), .manualSelfRenewal)
    }

    private func status(_ app: ManagedApp, enabled: Bool = true, sourceAvailable: Bool = true,
                        at date: Date? = nil) -> AppRenewalStatus {
        AppRenewalStatus.evaluate(app, enabled: enabled, sourceAvailable: sourceAvailable,
                                 runningBundleID: nil, now: date ?? now)
    }

    private func row() -> ManagedApp {
        var app = ManagedApp(id: UUID(), name: "Demo", identity: .init(appleID: "test@example.com", teamID: "TEAM",
            deviceUDID: "DEVICE", originalBundleID: "org.example.demo", signingBundleID: "org.example.demo"))
        app.sourceFile = UUID().uuidString + ".ipa"
        app.installedAt = now.addingTimeInterval(-86400)
        app.profileExpiry = now.addingTimeInterval(48 * 3600)
        app.certificateExpiry = now.addingTimeInterval(30 * 86400)
        return app
    }
}
