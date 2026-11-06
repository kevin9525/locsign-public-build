import XCTest
import XKit
import Dependencies
import OpenAPIRuntime
@testable import LocSign

final class DeveloperServicesGatewayTests: XCTestCase {
    func testCreatesExactBundleAndCertificateAndRevokesOnlyExplicitCertificateID() async throws {
        let transport = DeveloperAPIFixture()
        let gateway = try gateway(transport)
        let bundle = try await gateway.createBundleID("com.test.app", name: "Test")
        XCTAssertEqual(bundle.identifier, "com.test.app")
        let certificate = try await gateway.createDevelopmentCertificate(csr: "synthetic-csr")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.der, Data([1]))
        try await gateway.revokeCertificate(id: "explicit-cert")
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.path, "/v1/certificates/explicit-cert")
        XCTAssertEqual(requests.last?.override, "DELETE")
        let body = try XCTUnwrap(requests.first(where: { $0.path == "/v1/certificates" })?.body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let attributes = try XCTUnwrap((root["data"] as? [String: Any])?["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["csrContent"] as? String, "synthetic-csr")
        XCTAssertEqual(attributes["certificateType"] as? String, "DEVELOPMENT")
    }

    func testOrdinaryConflictDoesNotTriggerCertificateQuotaAndRawResponseIsNotExposed() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setConflict()
        do {
            _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
            XCTFail("Conflict accepted")
        } catch {
            XCTAssertEqual(error as? DeveloperServicesError, .rejected(409))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
        }
    }

    func testDeviceLookupAndRegistrationUseAppleMiddlewareAndExactUDID() async throws {
        let transport = DeveloperAPIFixture()
        let gateway = try gateway(transport)
        let devices = try await gateway.listDevices()
        XCTAssertEqual(devices, [.init(id: "device", udid: "SYNTHETIC-UDID", enabled: true)])
        let device = try await gateway.registerDevice(udid: "NEW-UDID")
        XCTAssertEqual(device.udid, "NEW-UDID")
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.host == "developerservices2.apple.com" && $0.token == "synthetic-token" && $0.team == "TEAM12345" })
        XCTAssertEqual(requests.last?.body?.contains("NEW-UDID"), true)
    }

    func testBundleLookupUpgradesPrefixResultsToExactEqualityAndReadsCapabilities() async throws {
        let transport = DeveloperAPIFixture()
        let gateway = try gateway(transport)
        let bundle = try await gateway.findExactBundleID("com.test.app")
        XCTAssertEqual(bundle?.id, "bundle")
        XCTAssertEqual(bundle?.identifier, "com.test.app")
        XCTAssertEqual(bundle?.capabilities, ["IN_APP_PURCHASE"])
        let absent = try await gateway.findExactBundleID("com.test.absent")
        XCTAssertNil(absent)
    }

    func testProfilesAndCertificatesPreserveContentAndCreateOnlyRequestedAssociations() async throws {
        let transport = DeveloperAPIFixture()
        let gateway = try gateway(transport)
        let certificates = try await gateway.listCertificates()
        XCTAssertEqual(certificates.map(\.id), ["cert"])
        XCTAssertEqual(certificates.first?.der, Data([1]))
        let profiles = try await gateway.listProfiles(bundleID: "bundle")
        XCTAssertEqual(profiles.first?.content, Data([2]))
        let profileReads = await transport.requests
        XCTAssertEqual(profileReads.last?.path, "/v1/bundleIds/bundle/profiles")
        _ = try await gateway.createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
        let requests = await transport.requests
        let body = try XCTUnwrap(requests.last?.body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let relationships = try XCTUnwrap(data["relationships"] as? [String: Any])
        XCTAssertEqual(Set(relationships.keys), ["bundleId", "devices", "certificates"])
        XCTAssertEqual((relationships["devices"] as? [String: Any])?["data"] as? [[String: String]], [["type": "devices", "id": "device"]])
        XCTAssertEqual((relationships["certificates"] as? [String: Any])?["data"] as? [[String: String]], [["type": "certificates", "id": "cert"]])
        XCTAssertFalse(requests.contains { $0.override == "DELETE" && $0.path.contains("profiles") })
    }

    private func gateway(_ transport: DeveloperAPIFixture) throws -> XKitDeveloperServicesGateway {
        let storage = MemoryKeyValueStorage()
        try storage.setString("fixture", forKey: "XTLADIProviderID")
        try storage.setData(Data([4]), forKey: "XTLProvisioningInfo")
        try storage.setString("42", forKey: "XTLRoutingInfo")
        let provider = try withDependencies {
            $0.keyValueStorage = storage
            $0.rawADIProvider = DeveloperRawFixture()
        } operation: { try ADIDataProvider(providerID: "fixture") }
        return XKitDeveloperServicesGateway(auth: .init(loginToken: .init(adsid: "synthetic-adsid", token: "synthetic-token", expiry: Date().addingTimeInterval(3600)), teamID: .init(rawValue: "TEAM12345")), provider: provider, client: transport)
    }
}

private struct DeveloperRawFixture: RawADIProvider {
    func clientInfo() async throws -> ClientInfoWithUserAgent { .init(clientInfo: "synthetic-client", akdUserAgent: "synthetic-agent") }
    func startProvisioning(spim: Data, userID: UUID) async throws -> (any RawADIProvisioningSession, Data) { throw DeveloperServicesError.invalidResponse }
    func requestOTP(userID: UUID, routingInfo: inout UInt64, provisioningInfo: Data) async throws -> (machineID: Data, otp: Data) { (Data([1]), Data([2])) }
}

private actor DeveloperAPIFixture: HTTPClientProtocol, ClientTransport {
    struct Request: Sendable { let host: String?; let path: String; let token: String?; let team: String?; let body: String?; let override: String? }
    var requests: [Request] = []
    private var conflict = false
    func setConflict() { conflict = true }
    nonisolated var asOpenAPITransport: any ClientTransport { self }
    func makeWebSocket(url: URL) async throws -> any WebSocketSession { throw DeveloperServicesError.invalidResponse }
    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T { try await perform(self) }
    func send(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        let bytes: Data
        if let body { bytes = try await body.reduce(into: Data()) { $0.append(contentsOf: $1) } } else { bytes = Data() }
        let json = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let data = json?["data"] as? [String: Any]
        let attributes = data?["attributes"] as? [String: Any]
        let query = json?["urlEncodedQueryParams"] as? String
        let team = attributes?["teamId"] as? String ?? URLComponents(string: "https://fixture.invalid/?" + (query ?? ""))?.queryItems?.first(where: { $0.name == "teamId" })?.value
        let method = request.headerFields[.init("X-HTTP-Method-Override")!] ?? request.method.rawValue
        let path = request.path ?? ""
        requests.append(.init(host: baseURL.host, path: path, token: request.headerFields[.init("X-Apple-GS-Token")!], team: team, body: String(data: bytes, encoding: .utf8), override: method))
        if conflict {
            let payload = ["errors": [["status": "409", "code": "ENTITY_ERROR", "title": "synthetic-sensitive-response", "detail": "synthetic-sensitive-response"]]]
            return (.init(status: .conflict, headerFields: [.contentType: "application/json"]), HTTPBody(try JSONSerialization.data(withJSONObject: payload)))
        }
        if path == "/v1/certificates/explicit-cert", method == "DELETE" {
            return (.init(status: .noContent), nil)
        }
        let payload: [String: Any]
        let status: XKit.HTTPResponse.Status
        if path == "/v1/devices", method == "POST" {
            payload = ["data": ["id": "new-device", "type": "devices", "attributes": ["udid": attributes?["udid"] as? String ?? "", "status": "ENABLED", "platform": "IOS"]]]
            status = .created
        } else if path == "/v1/devices" {
            payload = ["data": [["id": "device", "type": "devices", "attributes": ["udid": "SYNTHETIC-UDID", "status": "ENABLED", "platform": "IOS"]]]]
            status = .ok
        } else if path == "/v1/bundleIds", method == "POST" {
            payload = ["data": ["id": "bundle", "type": "bundleIds", "attributes": ["identifier": attributes?["identifier"] as? String ?? ""]]]
            status = .created
        } else if path == "/v1/bundleIds" {
            payload = ["data": [["id": "prefix", "type": "bundleIds", "attributes": ["identifier": "com.test.app.extra"]], ["id": "bundle", "type": "bundleIds", "attributes": ["identifier": "com.test.app"]]]]
            status = .ok
        } else if path == "/v1/bundleIds/bundle/bundleIdCapabilities" {
            payload = ["data": [["id": "cap", "type": "bundleIdCapabilities", "attributes": ["capabilityType": "IN_APP_PURCHASE"]]]]
            status = .ok
        } else if path == "/v1/certificates", method == "POST" {
            payload = ["data": ["id": "cert", "type": "certificates", "attributes": ["serialNumber": "01", "name": "Synthetic", "expirationDate": "2035-01-01T00:00:00Z", "certificateContent": "AQ==", "certificateType": "DEVELOPMENT"]]]
            status = .created
        } else if path == "/v1/certificates" {
            payload = ["data": [["id": "cert", "type": "certificates", "attributes": ["serialNumber": "01", "name": "Synthetic", "expirationDate": "2035-01-01T00:00:00Z", "certificateContent": "AQ==", "certificateType": "DEVELOPMENT"]]]]
            status = .ok
        } else if path == "/v1/profiles", method == "POST" {
            payload = ["data": ["id": "profile", "type": "profiles", "attributes": ["profileContent": "Ag=="]]]
            status = .created
        } else if path == "/v1/bundleIds/bundle/profiles" {
            payload = ["data": [["id": "profile", "type": "profiles", "attributes": ["profileContent": "Ag=="]]]]
            status = .ok
        } else { throw DeveloperServicesError.invalidResponse }
        var complete = payload
        complete["links"] = ["self": "https://developerservices2.apple.com/services" + path]
        return (.init(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(try JSONSerialization.data(withJSONObject: complete)))
    }
}
