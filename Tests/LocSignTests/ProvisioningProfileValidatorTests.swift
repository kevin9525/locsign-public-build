import XCTest
@testable import LocSign

final class ProvisioningProfileValidatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAcceptsAuthenticatedProfileWithDifferentTeamAndAppPrefix() throws {
        let result = try validate()
        XCTAssertEqual(result.uuid, "00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(result.profile.teamID, "TEAM12345")
        XCTAssertEqual(result.profile.bundleID, "com.test.app")
        XCTAssertEqual(result.profile.deviceUDIDs, ["SYNTHETIC-UDID"])
        XCTAssertEqual(result.certificateDER, try fixture("profile-dev", "cer"))
        XCTAssertEqual(result.raw, try fixture("profile-valid", "mobileprovision"))
        XCTAssertEqual(try PlistCodec.decode(result.signedContent) as? NSDictionary,
                       result.profile.payload as NSDictionary)
        XCTAssertGreaterThan(result.expiry, now)
        XCTAssertGreaterThan(result.certificateExpiry, now)
    }

    func testRejectsUnsignedPlistBeforeMetadataParsing() throws {
        assertRejects(.cms) { try self.validate(data: self.fixture("profile-unsigned", "plist")) }
    }

    func testProductionAppleRootsRejectSyntheticChain() throws {
        let anchors = try ["AppleIncRootCertificate", "AppleRootCA-G2", "AppleRootCA-G3"].map {
            try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: $0, withExtension: "cer")))
        }
        assertRejects(.cms) { try self.validate(anchors: anchors) }
    }

    func testRejectsEmbeddedRootUnlessExplicitlyTrusted() throws {
        assertRejects(.cms) { try self.validate(anchors: [self.fixture("unrelated-root", "der")]) }
    }

    func testRejectsWrongProfileSignerDespiteTrustedChain() throws {
        assertRejects(.cms) { try self.validate(name: "profile-wrong-signer") }
    }

    func testRejectsExpiredSigner() throws {
        assertRejects(.cms) { try self.validate(name: "profile-expired-signer") }
    }

    func testRejectsMultipleSigners() throws {
        assertRejects(.cms) { try self.validate(name: "profile-two-signers") }
    }

    func testRejectsTamperedSignedContent() throws {
        assertRejects(.cms) { try self.validate(name: "profile-tampered") }
    }

    func testRejectsTrailingUnsignedPlistAndSecondCMS() throws {
        let signed = try fixture("profile-valid", "mobileprovision")
        let unsigned = try fixture("profile-unsigned", "plist")
        assertRejects(.cms) { try self.validate(data: signed + unsigned) }
        assertRejects(.cms) { try self.validate(data: signed + signed) }
    }

    func testRejectsExpiredProfile() throws {
        assertRejects(.metadata) { try self.validate(name: "profile-expired") }
    }

    func testRequiresExactDeviceTeamAndBundle() throws {
        assertRejects(.metadata) { try self.validate(udid: "OTHER-DEVICE") }
        assertRejects(.metadata) { try self.validate(team: "OTHERTEAM") }
        assertRejects(.metadata) { try self.validate(bundle: "com.other.app") }
        assertRejects(.metadata) { try self.validate(name: "profile-wildcard") }
        assertRejects(.metadata) { try self.validate(name: "profile-wrong-prefix") }
    }

    func testRejectsUnsupportedCapabilities() throws {
        assertRejects(.metadata) { try self.validate(name: "profile-unsupported-entitlement") }
    }

    func testRequiresCertificateInSignedProfile() throws {
        assertRejects(.metadata) { try self.validate(certificate: self.fixture("profile-root", "cer")) }
    }

    func testRejectsMismatchedPrivateKey() throws {
        assertRejects(.certificate) { try self.validate(key: self.fixture("profile-other-key", "pem")) }
    }

    func testRejectsExpiredDevelopmentCertificate() throws {
        assertRejects(.certificate) {
            try self.validate(name: "profile-expired-certificate", certificate: self.fixture("profile-expired-dev", "cer"))
        }
    }

    private func validate(name: String = "profile-valid", data: Data? = nil,
                          anchors: [Data]? = nil, bundle: String = "com.test.app",
                          team: String = "TEAM12345", udid: String = "SYNTHETIC-UDID",
                          certificate: Data? = nil, key: Data? = nil) throws -> ValidatedProvisioningProfile {
        let validator = ProvisioningProfileValidator(trustAnchors: try anchors ?? [fixture("profile-root", "cer")], now: now)
        return try validator.validate(data: data ?? fixture(name, "mobileprovision"), expectedBundleID: bundle,
                                      expectedTeamID: team, expectedUDID: udid,
                                      expectedCertificateDER: certificate ?? fixture("profile-dev", "cer"),
                                      privateKeyPEM: key ?? fixture("test-key", "pem"))
    }

    private func assertRejects(_ expected: ProfileValidationError,
                               body: () throws -> ValidatedProvisioningProfile,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ProfileValidationError, expected, file: file, line: line)
        }
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
}
