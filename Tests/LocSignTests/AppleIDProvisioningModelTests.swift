import XCTest
@testable import LocSign

final class AppleIDProvisioningModelTests: XCTestCase {
    @MainActor
    func testRelaunchRestoresAvailableTeamButNeverSelectsTeamFromAnotherAccount() async throws {
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        addTeardownBlock { defaults.removePersistentDomain(forName: id); try? FileManager.default.removeItem(at: root) }
        let teams: [ProvisioningTeam] = [.init(id: "FIRST", name: "First"), .init(id: "SECOND", name: "Second")]
        let engine = AccountSheetEngineFixture(teams: teams)
        let first = AppleIDProvisioningModel(settings: InstallationSettings(directory: root, defaults: defaults)) { _ in engine }
        first.providerAccepted = true
        first.appleID = "user@example.com"; first.password = "synthetic"
        await first.logIn()
        first.teamID = "SECOND"
        let next = AppleIDProvisioningModel(settings: InstallationSettings(directory: root, defaults: defaults)) { _ in engine }
        next.appleID = "user@example.com"; next.password = "synthetic"
        await next.logIn()
        XCTAssertEqual(next.teamID, "SECOND")
        next.appleID = "other@example.com"; next.password = "synthetic"
        await next.logIn()
        XCTAssertTrue(next.teamID.isEmpty)
    }

    @MainActor
    func testReloginKeepsSelectedTeamWhenStillAvailable() async {
        let model = ready(AccountSheetEngineFixture(teams: [
            .init(id: "FIRST", name: "First"), .init(id: "SECOND", name: "Second")]))
        await model.logIn()
        model.teamID = "SECOND"
        model.password = "synthetic-password"
        await model.logIn()
        XCTAssertEqual(model.teamID, "SECOND")
    }

    @MainActor
    func testDisabledProviderRestoresCachedSigningAccountWithoutLogin() async {
        let engine = AccountSheetEngineFixture()
        let model = AppleIDProvisioningModel { _ in engine }
        model.providerEnabled = false
        await model.restore()
        XCTAssertEqual(model.account?.appleID, "user@example.com")
        XCTAssertEqual(model.teamID, "TEAM12345")
        let calls = await engine.loginCount
        XCTAssertEqual(calls, 0)
    }
    @MainActor
    func testSafeProviderFailureRemainsActionableInUI() async {
        let model = ready(AccountSheetEngineFixture(fail: true))
        await model.logIn()
        XCTAssertEqual(model.error, "Anisette 数据不可用，请检查提供方或重新登录")
    }
    @MainActor
    func testProviderConsentAndEnablementGateLogin() async {
        let engine = AccountSheetEngineFixture()
        let model = AppleIDProvisioningModel { _ in engine }
        model.appleID = "user@example.com"; model.password = "synthetic-password"
        await model.logIn()
        XCTAssertNotNil(model.error)
        var calls = await engine.loginCount
        XCTAssertEqual(calls, 0)
        model.providerAccepted = true; model.providerEnabled = false
        model.password = "synthetic-password"
        await model.logIn()
        calls = await engine.loginCount
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testLoginSelectsOnlyAvailableTeamAndClearsPassword() async {
        let engine = AccountSheetEngineFixture()
        let model = ready(engine)
        await model.logIn()
        XCTAssertEqual(model.account?.appleID, "user@example.com")
        XCTAssertEqual(model.teamID, "TEAM12345")
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testCancelledTwoFactorResumesOnceAndLateLoginCannotRestoreAccount() async {
        let engine = AccountSheetEngineFixture(twoFactor: true)
        let model = ready(engine)
        let task = Task { await model.logIn() }
        await fulfillment(of: [engine.codeRequested], timeout: 2)
        // Yield to the MainActor callback, bounded by the expectation above.
        for _ in 0..<20 where !model.awaitingCode { await Task.yield() }
        XCTAssertTrue(model.awaitingCode)
        XCTAssertTrue(model.password.isEmpty)
        await model.cancel()
        model.submitCode()
        await task.value
        XCTAssertNil(model.account)
        XCTAssertFalse(model.awaitingCode)
        XCTAssertTrue(model.code.isEmpty)
        let supplied = await engine.suppliedCode
        XCTAssertNil(supplied)
    }

    @MainActor
    func testRevocationDefaultsToRejectOnCancelAndCanConfirmExactList() async {
        let model = ready(AccountSheetEngineFixture())
        let list = [CertificateRevocation(id: "cert", serialNumber: "123", name: "Synthetic", expiry: .distantFuture)]
        let denied = Task { await model.confirmRevocation(list) }
        for _ in 0..<20 where model.revocations.isEmpty { await Task.yield() }
        XCTAssertEqual(model.revocations, list)
        await model.cancel()
        let first = await denied.value
        XCTAssertFalse(first)
        let accepted = Task { await model.confirmRevocation(list) }
        for _ in 0..<20 where model.revocations.isEmpty { await Task.yield() }
        model.resolveRevocation(true)
        let second = await accepted.value
        XCTAssertTrue(second)
        XCTAssertTrue(model.revocations.isEmpty)
    }

    @MainActor
    func testProviderChangeClearsAccountConsentAndCancelsPreviousEngine() async {
        let engine = AccountSheetEngineFixture()
        let model = ready(engine)
        await model.logIn()
        model.endpoint = "https://replacement.example.com"
        await model.changeProvider()
        XCTAssertNil(model.account)
        XCTAssertFalse(model.providerAccepted)
        XCTAssertEqual(model.teamID, "")
        let cancelled = await engine.cancelCount
        XCTAssertGreaterThan(cancelled, 0)
    }

    @MainActor
    private func ready(_ engine: AccountSheetEngineFixture) -> AppleIDProvisioningModel {
        let model = AppleIDProvisioningModel { _ in engine }
        model.providerAccepted = true
        model.appleID = "user@example.com"
        model.password = "synthetic-password"
        return model
    }

    @MainActor
    func testNoTeamCannotSignAndMultipleTeamsRequireSelection() async {
        let empty = ready(AccountSheetEngineFixture(teams: []))
        await empty.logIn()
        XCTAssertNil(empty.account)
        XCTAssertNotNil(empty.error)
        let multiple = ready(AccountSheetEngineFixture(teams: [.init(id: "FIRST", name: "First"), .init(id: "SECOND", name: "Second")]))
        await multiple.logIn()
        XCTAssertEqual(multiple.account?.teams.count, 2)
        XCTAssertTrue(multiple.teamID.isEmpty)
    }
}

private actor AccountSheetEngineFixture: ProvisioningEngine {
    nonisolated let codeRequested = XCTestExpectation(description: "Code requested")
    private let twoFactor: Bool
    private let teams: [ProvisioningTeam]
    private let fail: Bool
    private(set) var loginCount = 0
    private(set) var cancelCount = 0
    private(set) var suppliedCode: String?
    init(twoFactor: Bool = false, teams: [ProvisioningTeam] = [.init(id: "TEAM12345", name: "Synthetic")], fail: Bool = false) {
        self.twoFactor = twoFactor; self.teams = teams; self.fail = fail
    }
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount {
        loginCount += 1
        if fail { throw AppleAccountError.unavailable }
        if twoFactor { codeRequested.fulfill(); suppliedCode = await twoFactorCode() }
        return .init(id: UUID(), appleID: appleID, teams: teams)
    }
    func restoreAccount() async throws -> ProvisioningAccount? { nil }
    func restoreSigningAccount() async throws -> ProvisioningAccount? {
        .init(id: UUID(), appleID: "user@example.com", teams: [.init(id: "TEAM12345", name: "Synthetic")])
    }
    func cancel() async { cancelCount += 1 }
    func logout(account: String) async throws {}
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial { throw ProvisioningError.cancelled }
}
