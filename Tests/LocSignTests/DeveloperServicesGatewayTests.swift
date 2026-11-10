import XCTest
import XKit
import Dependencies
import OpenAPIRuntime
@testable import LocSign

final class DeveloperServicesGatewayTests: XCTestCase {
    func testSeparateProfileCreationsUseDistinctNamesWithSameSigningIdentity() async throws {
        let transport = DeveloperAPIFixture()
        let firstGateway = try gateway(transport)
        let secondGateway = try gateway(transport)
        _ = try await firstGateway.createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
        _ = try await secondGateway.createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let bodies = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap($0.body).utf8)) as? [String: Any]) }
        let first = try XCTUnwrap(bodies[0]["data"] as? [String: Any])
        let second = try XCTUnwrap(bodies[1]["data"] as? [String: Any])
        let firstAttributes = try XCTUnwrap(first["attributes"] as? [String: Any])
        let secondAttributes = try XCTUnwrap(second["attributes"] as? [String: Any])
        XCTAssertNotEqual(firstAttributes["name"] as? String, secondAttributes["name"] as? String)
        XCTAssertEqual(firstAttributes["profileType"] as? String, "IOS_APP_DEVELOPMENT")
        XCTAssertEqual(secondAttributes["profileType"] as? String, "IOS_APP_DEVELOPMENT")
        XCTAssertEqual(first["relationships"] as? NSDictionary, second["relationships"] as? NSDictionary)
        XCTAssertTrue(requests.allSatisfy { $0.path == "/v1/profiles" && $0.override == "POST" })
    }

    func testCancellationOnNameConflictPreventsSecondProfilePOST() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setProfileConflicts([["code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "A profile with name 'test' already exists on this team.", "source": ["pointer": "/data/attributes/name"]]])
        await transport.setCancelOnProfileConflict()
        let subject = try gateway(transport)
        let task = Task { try await subject.createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device") }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.override, "POST")
    }

    func testUnclassifiedProfileConflictNeverRetriesCreation() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setProfileConflicts([["code": "UNKNOWN", "detail": "synthetic-sensitive-response"]])
        do {
            _ = try await gateway(transport).createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
            XCTFail("Conflict ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 409"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testSecondProfileNameConflictStopsAfterOneRetry() async throws {
        let transport = DeveloperAPIFixture()
        let conflict: [String: Any] = ["code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "A profile with name 'synthetic-sensitive-response' already exists on this team.", "source": ["pointer": "/data/attributes/name"]]
        await transport.setProfileConflicts([conflict, conflict, conflict])
        do {
            _ = try await gateway(transport).createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
            XCTFail("Repeated conflict ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 409")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.override == "DELETE" })
    }

    func testExplicitProfileNameConflictRetriesOnceWithOnlyNameChanged() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setProfileConflicts([
            ["code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "A profile with name 'synthetic-sensitive-response' already exists on this team.",
             "source": ["pointer": "/data/attributes/name"]]
        ])
        let profile = try await gateway(transport).createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
        XCTAssertEqual(profile.id, "profile")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let bodies = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap($0.body).utf8)) as? [String: Any]) }
        let first = try XCTUnwrap(bodies[0]["data"] as? [String: Any])
        let second = try XCTUnwrap(bodies[1]["data"] as? [String: Any])
        let firstAttributes = try XCTUnwrap(first["attributes"] as? [String: Any])
        let secondAttributes = try XCTUnwrap(second["attributes"] as? [String: Any])
        XCTAssertNotEqual(firstAttributes["name"] as? String, secondAttributes["name"] as? String)
        XCTAssertEqual(firstAttributes["profileType"] as? String, "IOS_APP_DEVELOPMENT")
        XCTAssertEqual(secondAttributes["profileType"] as? String, "IOS_APP_DEVELOPMENT")
        XCTAssertEqual(first["relationships"] as? NSDictionary, second["relationships"] as? NSDictionary)
        XCTAssertTrue(requests.allSatisfy { $0.path == "/v1/profiles" && $0.override == "POST" })
    }

    func testProfileLimitConflictIsActionableWithoutNameRetryOrDeletion() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setProfileConflicts([
            ["code": "ENTITY_ERROR", "detail": "There is already a current iOS Development profile for this App ID. synthetic-sensitive-response"]
        ])
        do {
            _ = try await gateway(transport).createDevelopmentProfile(bundleID: "bundle", certificateID: "cert", deviceID: "device")
            XCTFail("Existing profile conflict accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已有描述文件"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 409"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.override == "DELETE" })
    }

    func testPendingKeyRecoversThroughRealGatewayAndProfileValidationWithoutNewCSR() async throws {
        func fixture(_ name: String, _ ext: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
        }
        let transport = DeveloperAPIFixture()
        let der = try certificateFixture()
        let profile = try fixture("profile-valid", "mobileprovision")
        await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: nil)
        await transport.setCertificateDetail(content: der)
        await transport.setProfileContent(profile)
        let pending = PendingSigningMaterial(privateKeyPEM: try fixture("test-key", "pem"), csr: "synthetic-csr", certificate: nil)
        let store = GatewayPendingStore(pending: pending)
        let provisioner = DeveloperServicesProvisioner(gateway: try gateway(transport), store: store,
            keys: GatewayUnusedKeys(), anchors: [try fixture("profile-root", "cer")], now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let material = try await provisioner.provision(app: .init(bundleID: "com.test.app", name: "Test"), deviceUDID: "SYNTHETIC-UDID", teamID: "TEAM12345", confirmRevocation: { _ in XCTFail("Recovery must not request revocation"); return false })
        XCTAssertEqual(material.profileData, profile)
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.path == "/v1/certificates/cert" })
        XCTAssertTrue(requests.allSatisfy { $0.override == "GET" })
        let saved = try await store.loadPending()
        XCTAssertEqual(saved?.certificate?.der, der)
    }

    func testLegacyCertificateInAttributesIsDecodedBeforeResourceResolution() async throws {
        let der = try certificateFixture()
        let transport = DeveloperAPIFixture()
        await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: nil)
        try await transport.setLegacyPayload(["resultCode": 0, "certRequest": ["attributes": ["certificateContent": der.base64EncodedString()]]])
        let certificate = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.der, der)
    }

    func testCertificateDetailFetchReturnsContentForExactRequestedResource() async throws {
        let der = try certificateFixture()
        let transport = DeveloperAPIFixture()
        await transport.setCertificateDetail(content: der)
        let certificate = try await gateway(transport).certificateDetails(id: "cert")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.der, der)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/v1/certificates/cert")
        XCTAssertEqual(requests.first?.override, "GET")
        XCTAssertFalse(requests.contains { $0.path.contains("submitDevelopmentCSR") })
    }

    func testCertificateDetailsRejectUnrelatedResourceAndNonDevelopmentType() async throws {
        for invalidType in [false, true] {
            let transport = DeveloperAPIFixture()
            await transport.setCertificateDetail(content: try certificateFixture(), id: invalidType ? "cert" : "other", type: invalidType ? "DISTRIBUTION" : "DEVELOPMENT")
            do { _ = try await gateway(transport).certificateDetails(id: "cert"); XCTFail("Unrelated certificate accepted") }
            catch { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .readCertificate, reason: .remoteChanged)) }
        }
    }

    func testCertificateDetailWithoutContentRemainsUnavailable() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setCertificateDetail(content: nil)
        let certificate = try await gateway(transport).certificateDetails(id: "cert")
        XCTAssertNil(certificate.der)
    }

    func testLegacyDirectAndNestedCertificateFieldsCannotBeAmbiguous() async throws {
        let transport = DeveloperAPIFixture()
        let der = try certificateFixture()
        try await transport.setLegacyPayload(["resultCode": 0, "certRequest": ["certContent": der, "attributes": ["certificateContent": der.base64EncodedString()]]])
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Ambiguous fields accepted") }
        catch { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .certificateResponse(.ambiguousContent))) }
    }

    func testLegacyPEMCertificateDataIsNormalizedBeforeResourceResolution() async throws {
        let der = try certificateFixture()
        let pem = "-----BEGIN CERTIFICATE-----\r\n" + der.base64EncodedString(options: .lineLength64Characters) + "\r\n-----END CERTIFICATE-----\r\n"
        let transport = DeveloperAPIFixture()
        await transport.setIssuedCertificate(Data(pem.utf8), listedSerial: "69", listedContent: der)
        let certificate = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.der, der)
    }

    func testLegacyPEMCertificateStringIsNormalizedBeforeResourceResolution() async throws {
        let der = try certificateFixture()
        let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString() + "\n-----END CERTIFICATE-----"
        let transport = DeveloperAPIFixture()
        await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: nil)
        try await transport.setLegacyPayload(["resultCode": 0, "certRequest": ["certContent": pem]])
        let certificate = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
        XCTAssertEqual(certificate.id, "cert")
        XCTAssertEqual(certificate.der, der)
    }

    func testLegacyBase64CertificateAliasesAndWhitespaceResolveTheSameCertificate() async throws {
        let der = try certificateFixture()
        for field in ["certContent", "certificateContent"] {
            let transport = DeveloperAPIFixture()
            await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: nil)
            let encoded = " \r\n" + der.base64EncodedString(options: .lineLength64Characters) + "\t\n"
            try await transport.setLegacyPayload(["resultCode": 0, "certRequest": [field: encoded]])
            let certificate = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr")
            XCTAssertEqual(certificate.der, der)
        }
    }

    func testCertificateResponseProblemsAreDistinctAndNeverEchoResponseValues() async throws {
        let cases: [([String: Any], CertificateResponseProblem)] = [
            (["unexpected": "synthetic-sensitive-response"], .envelope),
            (["resultCode": 0], .missingRequest),
            (["resultCode": 0, "certRequest": "synthetic-sensitive-response"], .missingRequest),
            (["resultCode": 0, "certRequest": ["other": "synthetic-sensitive-response"]], .missingContent),
            (["resultCode": 0, "certRequest": ["certContent": 17]], .contentType),
            (["resultCode": 0, "certRequest": ["certContent": Data()]], .emptyContent),
            (["resultCode": 0, "certRequest": ["certContent": "synthetic-sensitive-response"]], .encoding),
            (["resultCode": 0, "certRequest": ["certContent": Data([0x30, 0x01])]], .x509),
            (["resultCode": 0, "certRequest": ["certContent": Data([1]), "certificateContent": "AQ=="]], .ambiguousContent)
        ]
        for (payload, expected) in cases {
            let transport = DeveloperAPIFixture()
            try await transport.setLegacyPayload(payload)
            do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Invalid response accepted") }
            catch {
                XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .certificateResponse(expected)))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.path.contains("submitDevelopmentCSR") }.count, 1)
            XCTAssertFalse(requests.contains { $0.path == "/v1/certificates" || $0.override == "DELETE" })
        }
    }

    func testPEMRequiresOneCompleteCertificateWithoutExtraData() async throws {
        let der = try certificateFixture()
        let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString() + "\n-----END CERTIFICATE-----"
        let malformed = [pem + pem, "untrusted-prefix" + pem, pem + "untrusted-suffix",
                         pem.replacingOccurrences(of: "-----END CERTIFICATE-----", with: ""),
                         pem.replacingOccurrences(of: "BEGIN CERTIFICATE", with: "BEGIN PRIVATE KEY")]
        for content in malformed {
            let transport = DeveloperAPIFixture()
            await transport.setIssuedCertificate(Data(content.utf8), listedSerial: "69", listedContent: der)
            do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Malformed PEM accepted") }
            catch { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .certificateResponse(.encoding))) }
        }
    }

    func testIssuedCertificateRejectsTrailingDERAndNonCertificateASN1() async throws {
        for content in [try certificateFixture() + Data([0]), Data([0x30, 0x00])] {
            let transport = DeveloperAPIFixture()
            await transport.setIssuedCertificate(content, listedSerial: "69", listedContent: nil)
            do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Invalid X.509 accepted") }
            catch { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .certificateResponse(.x509))) }
        }
    }

    func testCertificateContentLimitRejectsOversizedResponseBeforeResolution() async throws {
        let transport = DeveloperAPIFixture()
        await transport.setIssuedCertificate(Data(repeating: 0x41, count: 1_048_577), listedSerial: "69", listedContent: nil)
        do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Oversized certificate accepted") }
        catch { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .certificateResponse(.oversizedContent))) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.path == "/v1/certificates" })
    }

    func testAppleRejectionCodeIsPreservedWithoutCertificateFields() async throws {
        for code in [3250, 7460] {
            let transport = DeveloperAPIFixture()
            try await transport.setLegacyPayload(["resultCode": code, "resultString": "synthetic-sensitive-response"])
            do { _ = try await gateway(transport).createDevelopmentCertificate(csr: "synthetic-csr"); XCTFail("Apple rejection ignored") }
            catch {
                if code == 7460 { XCTAssertEqual(error as? DeveloperServicesError, .certificateQuota) }
                else { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .createCertificate, reason: .appleRejected(code))) }
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-response"))
            }
        }
    }

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
        let der = try certificateFixture()
        await transport.setIssuedCertificate(der, listedSerial: "69", listedContent: der)
        let gateway = try gateway(transport)
        let issuer = LegacyDevelopmentCertificateIssuer(auth: gateway.auth, provider: gateway.provider, client: gateway.client)
        let certificate = try await issuer.issue(csr: "synthetic-csr")
        XCTAssertEqual(certificate, der)
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
    private var legacyPayload: Data?
    private var detailContent: Data?
    private var detailID = "cert"
    private var detailType = "DEVELOPMENT"
    private var profileContent = Data([2])
    private var certificateDate = "2035-01-01T00:00:00Z"
    private var malformedResponse = false
    private var transportFailure = false
    private var cancellation = false
    private var profileConflicts: [[String: Any]] = []
    private var cancelOnProfileConflict = false
    func setCancelOnProfileConflict() { cancelOnProfileConflict = true }
    func setProfileConflicts(_ values: [[String: Any]]) { profileConflicts = values }
    func setMalformedResponse() { malformedResponse = true }
    func setTransportFailure() { transportFailure = true }
    func setCancellation() { cancellation = true }
    func setConflict() { conflict = true }
    func setConflictDetail(_ value: String) { conflict = true; conflictDetail = value }
    func setCertificateDate(_ value: String) { certificateDate = value }
    func setLegacyResultCode(_ code: Int) { legacyResultCode = code }
    func setProfileContent(_ content: Data) { profileContent = content }
    func setCertificateDetail(content: Data?, id: String = "cert", type: String = "DEVELOPMENT") {
        detailContent = content; detailID = id; detailType = type
    }
    func setDuplicateCertificate() { duplicateCertificate = true }
    func setLegacyPayload(_ payload: [String: Any]) throws {
        legacyPayload = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }
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
        if path == "/v1/profiles", method == "POST", !profileConflicts.isEmpty {
            let error = profileConflicts.removeFirst()
            if cancelOnProfileConflict { withUnsafeCurrentTask { $0?.cancel() } }
            return (.init(status: .conflict, headerFields: [.contentType: "application/json"]),
                HTTPBody(try JSONSerialization.data(withJSONObject: ["errors": [error]])))
        }
        if !conflict, path.contains("ios/submitDevelopmentCSR.action"), let code = legacyResultCode {
            if let legacyPayload { return (.init(status: .ok), HTTPBody(legacyPayload)) }
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
        } else if path == "/v1/certificates/cert" {
            var certificateAttributes: [String: Any] = ["serialNumber": "69", "name": "Synthetic", "expirationDate": certificateDate, "certificateType": detailType]
            if let detailContent { certificateAttributes["certificateContent"] = detailContent.base64EncodedString() }
            payload = ["data": ["id": detailID, "type": "certificates", "attributes": certificateAttributes]]
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
            payload = ["data": [["id": "profile", "type": "profiles", "attributes": ["profileContent": profileContent.base64EncodedString()]]]]
            status = .ok
        } else { throw DeveloperServicesError.invalidResponse }
        var complete = payload
        complete["links"] = ["self": "https://developerservices2.apple.com/services" + path]
        return (.init(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(try JSONSerialization.data(withJSONObject: complete)))
    }
}

private struct GatewayUnusedKeys: ProvisioningKeyGenerating {
    func generate() throws -> PendingSigningMaterial { throw DeveloperServicesError.invalidResponse }
}
private actor GatewayPendingStore: ProvisioningMaterialStoring {
    var pending: PendingSigningMaterial?
    init(pending: PendingSigningMaterial) { self.pending = pending }
    func loadPending() async throws -> PendingSigningMaterial? { pending }
    func savePending(_ value: PendingSigningMaterial) async throws { pending = value }
    func invalidateCertificate(id: String) async throws { XCTFail("Recovery must not invalidate certificates") }
}
