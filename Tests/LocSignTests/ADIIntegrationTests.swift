import XCTest
import Dependencies
import XKit
import OpenAPIRuntime
@testable import LocSign

final class ADIIntegrationTests: XCTestCase {
    func testExplicitAppleAndRawProviderInjectionCompletesADIAndPersistsForReuse() async throws {
        let client = ADIAppleFixture()
        let raw = ADIRawFixture()
        let storage = MemoryKeyValueStorage()
        let provider = try withDependencies {
            $0.httpClient = client
            $0.rawADIProvider = raw
            $0.keyValueStorage = storage
        } operation: { try ADIDataProvider(providerID: "fixture-provider") }
        // ADI's lookup must use this raw provider's device info without capturing
        // the process default provider in its initializer.
        let value = try await provider.fetchAnisetteData()
        XCTAssertEqual(value.routingInfo, 42)
        XCTAssertEqual(value.oneTimePassword, "Ag==")
        XCTAssertEqual(value.deviceInfo.clientInfo, "synthetic-client")
        XCTAssertEqual(try storage.data(forKey: "XTLProvisioningInfo"), Data([4]))
        _ = try await provider.fetchAnisetteData()
        XCTAssertEqual(raw.provisioningCount, 1)
        XCTAssertEqual(raw.otpCount, 2)
    }
}

private final class ADIAppleFixture: HTTPClientProtocol, ClientTransport {
    var asOpenAPITransport: any ClientTransport { self }
    func makeWebSocket(url: URL) async throws -> any WebSocketSession { throw ProvisioningNetworkError.rejected }
    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T { try await perform(self) }
    func send(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        let payload: [String: Any]
        switch request.path {
        case "/grandslam/GsService2/lookup":
            payload = ["urls": Dictionary(uniqueKeysWithValues: ["gsService", "secondaryAuth", "trustedDeviceSecondaryAuth", "validateCode", "midStartProvisioning", "midFinishProvisioning"].map { ($0, "https://gsa.apple.com/" + $0) })]
        case "/midStartProvisioning": payload = ["Response": ["Status": ["ec": 0, "em": ""], "spim": "Ag=="]]
        case "/midFinishProvisioning": payload = ["Response": ["Status": ["ec": 0, "em": ""], "ptm": "BQ==", "tk": "Bg==", "X-Apple-I-MD-RINFO": "42"]]
        default: throw ProvisioningNetworkError.rejected
        }
        return (.init(status: .ok), HTTPBody(try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)))
    }
}

private final class ADIRawFixture: RawADIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var otps = 0
    var provisioningCount: Int { lock.withLock { starts } }
    var otpCount: Int { lock.withLock { otps } }
    func clientInfo() async throws -> ClientInfoWithUserAgent { .init(clientInfo: "synthetic-client", akdUserAgent: "synthetic-agent") }
    func startProvisioning(spim: Data, userID: UUID) async throws -> (any RawADIProvisioningSession, Data) {
        guard spim == Data([2]) else { throw ProvisioningNetworkError.invalidResponse }
        lock.withLock { starts += 1 }
        return (ADISessionFixture(), Data([3]))
    }
    func requestOTP(userID: UUID, routingInfo: inout UInt64, provisioningInfo: Data) async throws -> (machineID: Data, otp: Data) {
        guard routingInfo == 42, provisioningInfo == Data([4]) else { throw ProvisioningNetworkError.invalidResponse }
        lock.withLock { otps += 1 }
        return (Data([1]), Data([2]))
    }
}

private struct ADISessionFixture: RawADIProvisioningSession {
    func endProvisioning(routingInfo: UInt64, ptm: Data, tk: Data) async throws -> Data {
        guard routingInfo == 42, ptm == Data([5]), tk == Data([6]) else { throw ProvisioningNetworkError.invalidResponse }
        return Data([4])
    }
}
