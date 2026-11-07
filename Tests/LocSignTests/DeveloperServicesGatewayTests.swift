import XCTest
import XKit
import Dependencies
import OpenAPIRuntime
@testable import LocSign

final class DeveloperServicesGatewayTests: XCTestCase {
    func testIssuedCertificateResolvesMetadataOnlyListingBySerialAndRetainsIssuedBytes() async throws {
        let der = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "profile-dev", withExtension: "cer")))
        let transport = DeveloperAPIFixture()
        // The checked-in X.509 fixture has serial 0x69. REST need not repeat its DER.
        await transport.setIssuedCertificate(der, listedSerial: "000069", listedContent: nil)
        let certificate = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.serial, "000069")
        XCTAssertEqual(certificate.der, der)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.path.contains("submitDevelopmentCSR") }.count, 1)
        XCTAssertFalse(requests.contains { $0.override == "DELETE" })
    }

    func testLegacyMalformedCertificateResponseHasSpecificSafeDiagnosis() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setMalformedResponse()
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Malformed certificate accepted") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("证书签发响应"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
        }
    }

    func testIssuedCertificateRejectsUnrelatedSerialEvenWhenBytesMatch() async throws {
        let der = try certificateFixture()
        let transport = DeveloperAPIFixture()
        await transport.setIssuedCertificate(der, listedSerial: "70", listedContent: der)
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Unrelated serial accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("匹配已签发证书"), error.localizedDescription) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.override == "DELETE" })
    }

    func testIssuedCertificateRejectsDuplicateSerialAndConflictingCertificateContent() async throws {
        for duplicate in [false, true] {
            let der = try certificateFixture()
            let transport = DeveloperAPIFixture()
            await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: duplicate ? der : Data([2]))
            if duplicate { await transport.setDuplicateCertificate() }
            do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Ambiguous or conflicting certificate accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("匹配已签发证书"), error.localizedDescription) }
        }
    }

    func testIssuedCertificateMissingFromListReportsResolutionInsteadOfIssuance() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setIssuedCertificate(try certificateFixture(), listedSerial: "70", listedContent: nil)
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Unrelated certificate accepted") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("匹配已签发证书"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("尚未找到"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.path.contains("submitDevelopmentCSR") }.count, 1)
    }

    func testInvalidIssuedCertificateStopsBeforeReadingOrMutatingCertificateList() async throws {
        let transport = DeveloperAPIFixture()
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Invalid DER accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("证书签发响应"), error.localizedDescription) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.path == "/v1/certificates" })
    }

    func testRegistrationConflictDistinguishesUnavailableIdentifierFromRegistrationLimit() async throws {
        for (detail, expected) in [
            ("An App ID with Identifier 'synthetic-sensitive-response' is not available. Please enter a different string.", "应用标识不可用"),
            ("You may register a maximum of 10 App IDs every 7 days. synthetic-sensitive-response", "应用标识注册数量")
        ] {
            let transport = DeveloperAPIFixture()
            await transport.setConflictDetail(detail)
            do { _ = try await gateway(transport).createBundleID("com.test.app", name: "Test"); XCTFail("Conflict accepted") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("注册应用标识"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("HTTP 409"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
                XCTAssertNotEqual(error as? DeveloperServicesError, .certificateQuota)
            }
        }
    }

    func testBundleRejectionReportsStageAndHTTPStatusWithoutServerDetails() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setConflict()
        do { _ = try await gateway(transport).findExactBundleID("com.test.app"); XCTFail("Rejection accepted") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("查询应用标识"), message)
            XCTAssertTrue(message.contains("HTTP 409"), message)
            XCTAssertFalse(message.contains("synthetic-sensitive-response"))
        }
    }

    func testMalformedResponseIdentifiesOperationWithoutIncludingResponseData() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setMalformedResponse()
        do { _ = try await gateway(transport).listDevices(); XCTFail("Malformed response accepted") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("查询设备"), message)
            XCTAssertTrue(message.contains("返回的数据无效"), message)
            XCTAssertFalse(message.contains("synthetic-sensitive-response"))
        }
    }

    func testWrappedTransportFailureRemainsNetworkFailureWithOperation() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setTransportFailure()
        do { _ = try await gateway(transport).listCertificates(); XCTFail("Network failure accepted") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("查询开发证书"), message)
            XCTAssertTrue(message.contains("网络连接失败"), message)
            XCTAssertFalse(message.contains("返回的数据无效"), message)
        }
    }

    func testWrappedCancellationDoesNotBecomeAnInvalidResponse() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setCancellation()
        do { _ = try await gateway(transport).listDevices(); XCTFail("Cancellation accepted") }
        catch { XCTAssertTrue(error is CancellationError, String(describing: error)) }
    }

    func testLegacyIssuanceRejectionReportsAppleCodeAndStage() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setLegacyResultCode(3250)
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Rejection accepted") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("申请开发证书"), message)
            XCTAssertTrue(message.contains("Apple 3250"), message)
            XCTAssertFalse(message.contains("synthetic-sensitive-response"))
        }
    }

    func testCertificateDatesAcceptAppleFractionalSecondsAndPreserveTheExpiry() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setCertificateDate("2035-01-01T00:00:00.000+00:00")
        let certificates = try await gateway(transport).listCertificates()
        XCTAssertEqual(certificates.first?.expiry, Date(timeIntervalSince1970: 2_051_222_400))
    }
    func testLegacyIssuerRecognizesOnlyExplicitQuotaCodeAndDoesNotExposeReason() async throws {
        for code in [7460, 3250] {
            let transport = DeveloperAPIFixture()
            await transport.setLegacyResultCode(code)
            let gateway = try gateway(transport)
            let issuer = LegacyDevelopmentCertificateIssuer(auth: gateway.auth, provider: gateway.provider, client: gateway.client)
            do { _ = try await issuer.issue(csr: "synthetic-csr"); XCTFail("Rejected issuance accepted") }
            catch {
                XCTAssertEqual(error as? DeveloperServicesError, code == 7460 ? .certificateQuota : .appleRejected(code))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
            }
        }
    }

    func testLegacyIssuerSendsOnlyCSRAndSelectedTeamAndReturnsCertificateBytes() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setLegacyResultCode(0)
        let gateway = try gateway(transport)
        let issuer = LegacyDevelopmentCertificateIssuer(auth: gateway.auth, provider: gateway.provider, client: gateway.client)
        let certificate = try await issuer.issue(csr: "synthetic-csr")
        XCTAssertEqual(certificate, Data([1]))
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertTrue(request.path.contains("ios/submitDevelopmentCSR.action"))
        XCTAssertEqual(request.host, "developerservices2.apple.com")
        XCTAssertEqual(request.team, "TEAM12345")
        XCTAssertEqual(request.token, "synthetic-token")
        let body = try XCTUnwrap(request.body).data(using: .utf8)!
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
        XCTAssertEqual(plist["csrContent"] as? String, "synthetic-csr")
        XCTAssertNil(plist["privateKey"])
    }

    func testCreatesExactBundleAndCertificateAndRevokesOnlyExplicitCertificateID() async throws {
        let transport = DeveloperAPIFixture()
        let der = try certificateFixture()
        await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: der)
        let gateway = try gateway(transport)
        let bundle = try await gateway.createBundleID("com.test.app", name: "Test")
        XCTAssertEqual(bundle.identifier, "com.test.app")
        let certificate = try await gateway.createDevelopmentCertificate(csr: "synthetic-csr")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.der, der)
        try await gateway.revokeCertificate(id: "explicit-cert")
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.path, "/v1/certificates/explicit-cert")
        XCTAssertEqual(requests.last?.override, "DELETE")
        let body = try XCTUnwrap(requests.first(where: { $0.path.contains("ios/submitDevelopmentCSR.action") })?.body)
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(body.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(root["csrContent"] as? String, "synthetic-csr")
        XCTAssertEqual(root["teamId"] as? String, "TEAM12345")
        XCTAssertNil(root["privateKey"])
    }

    func testGatewaySurfacesExplicitIssuanceQuotaWithoutDeletingAnything() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setLegacyResultCode(7460)
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Quota ignored") }
        catch { XCTAssertEqual(error as? DeveloperServicesError, .certificateQuota) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.override == "DELETE" })
    }

    func testOrdinaryConflictDoesNotTriggerCertificateQuotaAndRawResponseIsNotExposed() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setConflict()
        do {
            _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
            XCTFail("Conflict accepted")
        } catch {
            XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .rejected(409)))
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

    private func certificateFixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "profile-dev", withExtension: "cer")))
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
    private var conflictDetail = "synthetic-sensitive-response"
    private var legacyResultCode: Int? = 0
    private var issuedCertificate = Data([1])
    private var listedSerial = "01"
    private var listedContent: Data? = Data([1])
    private var duplicateCertificate = false
    private var certificateDate = "2035-01-01T00:00:00Z"
    private var malformedResponse = false
    private var transportFailure = false
    private var cancellation = false
    func setMalformedResponse() { malformedResponse = true }
    func setTransportFailure() { transportFailure = true }
    func setCancellation() { cancellation = true }
    func setConflict() { conflict = true }
    func setConflictDetail(_ value: String) { conflict = true; conflictDetail = value }
    func setCertificateDate(_ value: String) { certificateDate = value }
    func setLegacyResultCode(_ code: Int) { legacyResultCode = code }
    func setDuplicateCertificate() { duplicateCertificate = true }
    func setIssuedCertificate(_ der: Data, listedSerial: String, listedContent: Data?) {
        issuedCertificate = der
        self.listedSerial = listedSerial
        self.listedContent = listedContent
    }
    nonisolated var asOpenAPITransport: any ClientTransport { self }
    func makeWebSocket(url: URL) async throws -> any WebSocketSession { throw DeveloperServicesError.invalidResponse }
    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T { try await perform(self) }
    func send(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        if cancellation { throw CancellationError() }
        if transportFailure { throw ProvisioningNetworkError.transport }
        if malformedResponse {
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]),
                    HTTPBody(Data("synthetic-sensitive-response".utf8)))
        }
        let bytes: Data
        if let body { bytes = try await body.reduce(into: Data()) { $0.append(contentsOf: $1) } } else { bytes = Data() }
        let json = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]) ??
                   ((try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any])
        let data = json?["data"] as? [String: Any]
        let attributes = data?["attributes"] as? [String: Any]
        let query = json?["urlEncodedQueryParams"] as? String
        let team = attributes?["teamId"] as? String ?? json?["teamId"] as? String ?? URLComponents(string: "https://fixture.invalid/?" + (query ?? ""))?.queryItems?.first(where: { $0.name == "teamId" })?.value
        let method = request.headerFields[.init("X-HTTP-Method-Override")!] ?? request.method.rawValue
        let path = request.path ?? ""
        requests.append(.init(host: baseURL.host, path: path, token: request.headerFields[.init("X-Apple-GS-Token")!], team: team, body: String(data: bytes, encoding: .utf8), override: method))
        if !conflict, path.contains("ios/submitDevelopmentCSR.action"), let code = legacyResultCode {
            let payload: [String: Any] = ["resultCode": code, "resultString": "synthetic-sensitive-response", "certRequest": ["certContent": issuedCertificate]]
            return (.init(status: .ok), HTTPBody(try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)))
        }
        if conflict {
            let payload = ["errors": [["status": "409", "code": "ENTITY_ERROR", "title": "synthetic-sensitive-response", "detail": conflictDetail]]]
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
            payload = ["data": ["id": "cert", "type": "certificates", "attributes": ["serialNumber": "01", "name": "Synthetic", "expirationDate": certificateDate, "certificateContent": "AQ==", "certificateType": "DEVELOPMENT"]]]
            status = .created
        } else if path == "/v1/certificates" {
            var certificateAttributes: [String: Any] = ["serialNumber": listedSerial, "name": "Synthetic", "expirationDate": certificateDate, "certificateType": "DEVELOPMENT"]
            if let listedContent { certificateAttributes["certificateContent"] = listedContent.base64EncodedString() }
            var certificates: [[String: Any]] = [["id": "cert", "type": "certificates", "attributes": certificateAttributes]]
            if duplicateCertificate { certificates.append(["id": "another-cert", "type": "certificates", "attributes": certificateAttributes]) }
            payload = ["data": certificates]
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
