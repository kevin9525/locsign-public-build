import XCTest
import XKit
@testable import LocSign

final class AppleAccountClientTests: XCTestCase {
    func testLoginNormalizesAccountAndReturnsOnlySupportedFreeTeams() async throws {
        let gateway = AccountGatewayFixture()
        let client = AppleAccountClient(gateway: gateway, providerID: "fixture")
        let session = try await client.logIn(appleID: " User@Example.COM \n", password: "synthetic-password", twoFactorCode: { "123456" })
        XCTAssertEqual(session.account.appleID, "user@example.com")
        XCTAssertEqual(session.account.teams.map(\.id), ["FREE1", "FREE2"])
        XCTAssertEqual(gateway.username, "user@example.com")
        XCTAssertEqual(session.providerID, "fixture")
        XCTAssertGreaterThan(session.token.expiry, Date())
        XCTAssertFalse(String(describing: session.account).contains("synthetic-token"))
    }

    func testAuthenticationFailuresAreTypedAndNeverContainRawReason() async throws {
        for expected in [AppleAccountError.invalidCredentials, .accountLocked, .invalidCode, .unavailable] {
            let gateway = AccountGatewayFixture(failure: expected)
            do {
                _ = try await AppleAccountClient(gateway: gateway, providerID: "fixture").logIn(appleID: "u@example.com", password: "synthetic-password", twoFactorCode: { "123456" })
                XCTFail("Authentication failure ignored")
            } catch {
                XCTAssertEqual(error as? AppleAccountError, expected)
                XCTAssertEqual(gateway.teamRequests, 0)
            }
        }
        let gateway = AccountGatewayFixture(failure: NSError(domain: "synthetic-token", code: 9, userInfo: [NSLocalizedDescriptionKey: "synthetic-password"]))
        do { _ = try await AppleAccountClient(gateway: gateway, providerID: "fixture").logIn(appleID: "u@example.com", password: "synthetic-password", twoFactorCode: { nil }); XCTFail("Unknown error ignored") }
        catch {
            XCTAssertEqual(error as? AppleAccountError, .rejected(nil))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-password"))
        }
    }

    func testTwoFactorCancelStopsBeforeTeamRequestsAndNewLoginCanRetry() async throws {
        let gateway = AccountGatewayFixture(requiresCode: true)
        let client = AppleAccountClient(gateway: gateway, providerID: "fixture")
        let count = AccountCallbackCounter()
        do { _ = try await client.logIn(appleID: "u@example.com", password: "synthetic-password", twoFactorCode: { await count.next(nil) }); XCTFail("Cancel ignored") }
        catch { XCTAssertEqual(error as? AppleAccountError, .cancelled) }
        let called = await count.value
        XCTAssertEqual(called, 1)
        XCTAssertEqual(gateway.teamRequests, 0)
        _ = try await client.logIn(appleID: "u@example.com", password: "synthetic-password", twoFactorCode: { "123456" })
        XCTAssertEqual(gateway.teamRequests, 1)
    }

    func testNoSupportedTeamAndExpiredTokenAreRejected() async throws {
        for gateway in [AccountGatewayFixture(teamPayload: []), AccountGatewayFixture(expired: true)] {
            do {
                _ = try await AppleAccountClient(gateway: gateway, providerID: "fixture").logIn(appleID: "u@example.com", password: "synthetic-password", twoFactorCode: { nil })
                XCTFail("Unusable account accepted")
            } catch { XCTAssertTrue(error is AppleAccountError) }
        }
    }

    func testCancellationBeforeLoginDoesNotCallGateway() async throws {
        let gateway = AccountGatewayFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleAccountClient(gateway: gateway, providerID: "fixture").logIn(appleID: "u@example.com", password: "synthetic-password", twoFactorCode: { nil })
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError || error as? AppleAccountError == .cancelled) }
        XCTAssertNil(gateway.username)
    }
}

private actor AccountCallbackCounter {
    var value = 0
    func next(_ code: String?) -> String? { value += 1; return code }
}

private final class AccountGatewayFixture: AppleAccountGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    private var requests = 0
    let failure: Error?
    let requiresCode: Bool
    let expired: Bool
    let teamPayload: [[String: Any]]
    var username: String? { lock.withLock { name } }
    var teamRequests: Int { lock.withLock { requests } }
    init(failure: Error? = nil, requiresCode: Bool = false, expired: Bool = false, teamPayload: [[String: Any]]? = nil) {
        self.failure = failure; self.requiresCode = requiresCode; self.expired = expired
        self.teamPayload = teamPayload ?? [
            ["teamId": "FREE1", "status": "active", "name": "Personal", "memberships": [["name": "Free Provisioning", "platform": "ios"]]],
            ["teamId": "PAID", "status": "active", "name": "Paid", "memberships": [["name": "Apple Developer Program", "platform": "ios"]]],
            ["teamId": "MAC", "status": "active", "name": "Mac", "memberships": [["name": "Free Provisioning", "platform": "mac"]]],
            ["teamId": "INACTIVE", "status": "inactive", "name": "Inactive", "memberships": [["name": "Free Provisioning", "platform": "ios"]]],
            ["teamId": "FREE2", "status": "active", "name": "Personal 2", "memberships": [["name": "Free Provisioning", "platform": "ios"]]]
        ]
    }
    func authenticate(appleID: String, password: String, twoFactor: @escaping TwoFactorCodeProvider) async throws -> DeveloperServicesLoginToken {
        lock.withLock { name = appleID }
        if let failure { throw failure }
        if requiresCode {
            guard let code = await twoFactor() else { throw AppleAccountError.cancelled }
            guard code == "123456" else { throw AppleAccountError.invalidCode }
        }
        return .init(adsid: "synthetic-adsid", token: "synthetic-token", expiry: Date().addingTimeInterval(expired ? -3600 : 3600))
    }
    func teams(token: DeveloperServicesLoginToken) async throws -> [DeveloperServicesTeam] {
        lock.withLock { requests += 1 }
        return try JSONDecoder().decode([DeveloperServicesTeam].self, from: JSONSerialization.data(withJSONObject: teamPayload))
    }
}
