import XCTest
@testable import LocSign

final class InstalledSelfProfileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadsAuthenticatedRunningIdentityWithoutAnAppLibraryRecord() throws {
        let profile = try read("profile-valid")
        XCTAssertEqual(profile.bundleID, "com.test.app")
        XCTAssertEqual(profile.teamID, "TEAM12345")
        XCTAssertEqual(profile.profileExpiry, Date(timeIntervalSince1970: 4_070_908_800))
    }

    func testRejectsTamperedUnsignedOrDifferentRunningApp() throws {
        for name in ["profile-tampered", "profile-wrong-signer"] {
            XCTAssertThrowsError(try read(name))
        }
        XCTAssertThrowsError(try read("profile-valid", bundleID: "com.other.app"))
        XCTAssertThrowsError(try InstalledSelfProfile.read(data: fixture("profile-unsigned", "plist"),
            bundleID: "com.test.app", trustAnchors: [fixture("profile-root", "cer")], now: now))
    }

    func testExpiredProfileCanBeDisplayedWithoutBeingCalledValid() throws {
        let profile = try read("profile-expired")
        XCTAssertLessThanOrEqual(profile.profileExpiry, now)
        XCTAssertTrue(SelfRenewalReminder.plan(expiry: profile.profileExpiry, now: now).isEmpty)
    }

    func testRemindersUseActualExpiryAndOnlyFutureThresholds() {
        let expiry = now.addingTimeInterval(7 * 86400)
        XCTAssertEqual(SelfRenewalReminder.plan(expiry: expiry, now: now).map(\.date),
                       [now.addingTimeInterval(5 * 86400), now.addingTimeInterval(6 * 86400)])
        XCTAssertEqual(SelfRenewalReminder.plan(expiry: expiry, now: expiry.addingTimeInterval(-36 * 3600)).map(\.date),
                       [expiry.addingTimeInterval(-24 * 3600)])
        XCTAssertTrue(SelfRenewalReminder.plan(expiry: expiry, now: expiry.addingTimeInterval(-3600)).isEmpty)
    }

    private func read(_ name: String, bundleID: String = "com.test.app") throws -> InstalledSelfProfile {
        try InstalledSelfProfile.read(data: fixture(name, "mobileprovision"), bundleID: bundleID,
            trustAnchors: [fixture("profile-root", "cer")], now: now)
    }
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
}

@MainActor
final class SelfRenewalModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEnablingRemindersSchedulesBothAndNewProfileReplacesOldDates() async throws {
        let notifications = SelfReminderCenterFixture()
        var profile = InstalledSelfProfile(bundleID: "com.test.app", teamID: "TEAM", profileExpiry: now.addingTimeInterval(7 * 86400))
        let model = SelfRenewalModel(defaults: defaults(), notifications: notifications, now: { self.now }, readProfile: { profile })
        await model.refresh()
        XCTAssertTrue(notifications.pending.isEmpty)
        await model.setRemindersEnabled(true)
        XCTAssertEqual(notifications.pending.values.map(\.date).sorted(),
                       [now.addingTimeInterval(5 * 86400), now.addingTimeInterval(6 * 86400)])
        profile = .init(bundleID: "com.test.app", teamID: "TEAM", profileExpiry: now.addingTimeInterval(10 * 86400))
        await model.refresh()
        XCTAssertEqual(notifications.pending.values.map(\.date).sorted(),
                       [now.addingTimeInterval(8 * 86400), now.addingTimeInterval(9 * 86400)])
        XCTAssertEqual(model.profile?.profileExpiry, profile.profileExpiry)
        XCTAssertNil(model.notificationError)
    }

    func testDisabledOrUnauthorizedRemindersCannotRemainQueued() async throws {
        let notifications = SelfReminderCenterFixture()
        let model = makeModel(notifications)
        await model.refresh()
        await model.setRemindersEnabled(true)
        await model.setRemindersEnabled(false)
        XCTAssertTrue(notifications.pending.isEmpty)
        XCTAssertFalse(model.remindersEnabled)
        notifications.authorized = false
        await model.setRemindersEnabled(true)
        XCTAssertFalse(model.remindersEnabled)
        XCTAssertTrue(notifications.pending.isEmpty)
        XCTAssertNotNil(model.notificationError)
    }

    func testMissingProfileCancelsOldReminderWithoutInventingSevenDays() async {
        let notifications = SelfReminderCenterFixture()
        var available = true
        let model = SelfRenewalModel(defaults: defaults(), notifications: notifications, now: { self.now }, readProfile: {
            if !available { throw ProfileValidationError.cms }
            return .init(bundleID: "com.test.app", teamID: "TEAM", profileExpiry: self.now.addingTimeInterval(7 * 86400))
        })
        await model.refresh()
        await model.setRemindersEnabled(true)
        available = false
        await model.refresh()
        XCTAssertNil(model.profile)
        XCTAssertNotNil(model.profileError)
        XCTAssertTrue(notifications.pending.isEmpty)
    }

    func testSchedulingFailureIsVisibleAndOnlyOwnedRequestsAreRemoved() async {
        let notifications = SelfReminderCenterFixture()
        notifications.failAdd = true
        let model = makeModel(notifications)
        await model.refresh()
        await model.setRemindersEnabled(true)
        XCTAssertNotNil(model.notificationError)
        XCTAssertEqual(Set(notifications.removed), Set(SelfRenewalReminder.identifiers))
    }

    func testDisablingWhileAddIsInFlightLeavesNoLateReminders() async {
        let notifications = SelfReminderCenterFixture()
        notifications.delayAdd = true
        let model = makeModel(notifications)
        await model.refresh()
        let enable = Task { await model.setRemindersEnabled(true) }
        await fulfillment(of: [notifications.entered], timeout: 3)
        let disable = Task { await model.setRemindersEnabled(false) }
        await Task.yield()
        notifications.release()
        await enable.value
        await disable.value
        XCTAssertTrue(notifications.pending.isEmpty)
        XCTAssertFalse(model.remindersEnabled)
    }

    private func makeModel(_ center: SelfReminderCenterFixture) -> SelfRenewalModel {
        SelfRenewalModel(defaults: defaults(), notifications: center, now: { self.now }, readProfile: {
            .init(bundleID: "com.test.app", teamID: "TEAM", profileExpiry: self.now.addingTimeInterval(7 * 86400))
        })
    }
    private func defaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

@MainActor
private final class SelfReminderCenterFixture: SelfRenewalNotificationCenter {
    var authorized = true
    var failAdd = false
    var delayAdd = false
    var pending: [String: SelfRenewalReminder] = [:]
    var removed: [String] = []
    let entered = XCTestExpectation(description: "Notification add entered")
    private var continuation: CheckedContinuation<Void, Never>?
    func requestPermission() async -> Bool { authorized }
    func isAuthorized() async -> Bool { authorized }
    func removePending(_ identifiers: [String]) {
        removed += identifiers
        for id in identifiers { pending[id] = nil }
    }
    func add(_ reminder: SelfRenewalReminder) async throws {
        if failAdd { throw URLError(.unknown) }
        if delayAdd {
            delayAdd = false
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        pending[reminder.id] = reminder
    }
    func release() { continuation?.resume(); continuation = nil }
}
