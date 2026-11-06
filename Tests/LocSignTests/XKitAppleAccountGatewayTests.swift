import XCTest
import XKit
import Dependencies
import OpenAPIRuntime
@testable import LocSign

final class XKitAppleAccountGatewayTests: XCTestCase {
    func testLiveContextInjectsProviderSpecificKeychainBeforeNetwork() throws {
        let keychain = ProvisioningKeychain(api: SpyProvisioningKeychainAPI())
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let gateway = try XKitAppleAccountGateway(configuration: config, keychain: keychain, account: "u@example.com")
        XCTAssertEqual(gateway.provider.providerID, "omnisette-v3:https://fixture.invalid")
        let data = try keychain.read(account: "u@example.com", provider: config.providerID, team: "", key: "anisette.XTLLocalUserUID")
        XCTAssertNotNil(data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:)))
        let storage = try XCTUnwrap(gateway.storage)
        storage.invalidate()
        XCTAssertThrowsError(try storage.setData(Data([1]), forKey: "state")) { XCTAssertTrue($0 is CancellationError) }
    }

    func testTwoFactorDelegateSubmitsOneTrimmedCodeAndClearsCallback() async {
        let count = CodeCallbackCount()
        let delegate = AppleTwoFactorDelegate { await count.increment(); return " 123456\n" }
        let first = await delegate.fetchCode()
        let second = await delegate.fetchCode()
        XCTAssertEqual(first, "123456")
        XCTAssertNil(second)
        let calls = await count.value
        XCTAssertEqual(calls, 1)
    }

    func testTwoFactorDelegateRejectsMalformedCodeAndHonorsCancellation() async {
        let malformed = await AppleTwoFactorDelegate { "123abc" }.fetchCode()
        XCTAssertNil(malformed)
        let count = CodeCallbackCount()
        let delegate = AppleTwoFactorDelegate { await count.increment(); return "123456" }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await delegate.fetchCode()
        }
        let result = await task.value
        XCTAssertNil(result)
        let calls = await count.value
        XCTAssertEqual(calls, 0)
    }

    func testRealGrandSlamStatusMappingNeverExposesServerMessage() async throws {
        for (code, expected) in [(-20101, AppleAccountError.invalidCredentials), (-22406, .invalidCredentials), (-22421, .unavailable), (-21669, .invalidCode), (-99999, .rejected(-99999))] {
            let gateway = try gateway(errorCode: code)
            do { _ = try await gateway.authenticate(appleID: "u@example.com", password: "synthetic-password", twoFactor: { nil }); XCTFail("Server rejection ignored") }
            catch {
                XCTAssertEqual(error as? AppleAccountError, expected)
                XCTAssertFalse(String(describing: error).contains("synthetic-server-secret"))
            }
        }
    }

    func testLiveTeamRequestCarriesTokenOnlyToAppleTransport() async throws {
        let gateway = try gateway(errorCode: 0)
        let teams = try await gateway.teams(token: .init(adsid: "synthetic-adsid", token: "synthetic-token", expiry: Date().addingTimeInterval(3600)))
        XCTAssertEqual(teams.map { $0.id.rawValue }, ["FREE"])
    }

    private func gateway(errorCode: Int) throws -> XKitAppleAccountGateway {
        let storage = MemoryKeyValueStorage()
        try storage.setString(UUID().uuidString, forKey: "XTLLocalUserUID")
        try storage.setString("fixture", forKey: "XTLADIProviderID")
        try storage.setData(Data([4]), forKey: "XTLProvisioningInfo")
        try storage.setString("42", forKey: "XTLRoutingInfo")
        let provider = try withDependencies {
            $0.keyValueStorage = storage
            $0.rawADIProvider = AccountRawADI()
        } operation: { try ADIDataProvider(providerID: "fixture") }
        return XKitAppleAccountGateway(provider: provider, client: AccountAppleHTTP(errorCode: errorCode))
    }
}

private actor CodeCallbackCount { var value = 0; func increment() { value += 1 } }

private struct AccountRawADI: RawADIProvider {
    func clientInfo() async throws -> ClientInfoWithUserAgent { .init(clientInfo: "synthetic-client", akdUserAgent: "synthetic-agent") }
    func startProvisioning(spim: Data, userID: UUID) async throws -> (any RawADIProvisioningSession, Data) { throw ProvisioningNetworkError.rejected }
    func requestOTP(userID: UUID, routingInfo: inout UInt64, provisioningInfo: Data) async throws -> (machineID: Data, otp: Data) { (Data([1]), Data([2])) }
}

private struct AccountAppleHTTP: HTTPClientProtocol, ClientTransport {
    let errorCode: Int
    var asOpenAPITransport: any ClientTransport { self }
    func makeWebSocket(url: URL) async throws -> any WebSocketSession { throw ProvisioningNetworkError.rejected }
    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T { try await perform(self) }
    func send(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        let payload: [String: Any]
        guard request.authority == "gsa.apple.com" || request.authority == "developerservices2.apple.com" else { throw ProvisioningNetworkError.rejected }
        if request.path?.contains("lookup") == true {
            payload = ["urls": Dictionary(uniqueKeysWithValues: ["gsService", "secondaryAuth", "trustedDeviceSecondaryAuth", "validateCode", "midStartProvisioning", "midFinishProvisioning"].map { ($0, "https://gsa.apple.com/" + $0) })]
        } else if request.path?.contains("listTeams") == true {
            guard request.headerFields[.init("X-Apple-GS-Token")!] == "synthetic-token",
                  request.headerFields[.init("X-Apple-I-Identity-Id")!] == "synthetic-adsid" else { throw ProvisioningNetworkError.rejected }
            payload = ["resultCode": 0, "teams": [["teamId": "FREE", "status": "active", "name": "Personal", "memberships": [["name": "Free Provisioning", "platform": "ios"]]]]]
        } else {
            payload = ["Response": ["Status": ["ec": errorCode, "em": "synthetic-server-secret"]]]
        }
        return (.init(status: .ok), HTTPBody(try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)))
    }
}
