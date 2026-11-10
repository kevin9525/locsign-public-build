import XCTest
@testable import LocSign

final class DeveloperProfileDiagnosticsTests: XCTestCase {
    func testOnlyExplicitNameCollisionAuthorizesNameRetry() throws {
        let response = try payload(code: "ENTITY_ERROR.ATTRIBUTE.INVALID",
            detail: "A profile with name 'secret@example.com' already exists on this team.", pointer: "/data/attributes/name")
        XCTAssertEqual(DeveloperProfileDiagnostics.rejection(status: 409, data: response), .profileRejected(409, .nameConflict))
        for detail in ["A profile with name 'already exists' cannot be created.", "A certificate named 'profile already exists' is invalid."] {
            let data = try payload(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", detail: detail, pointer: "/data/attributes/name")
            XCTAssertNotEqual(DeveloperProfileDiagnostics.rejection(status: 409, data: data), .profileRejected(409, .nameConflict))
        }
    }

    func testRelationshipAndProfileLimitReasonsAreDistinctAndNeverLeakValues() throws {
        let cases: [(String, String, DeveloperProfileReason)] = [
            ("There is already a current iOS Development profile for this App ID. secret@example.com", "", .existingProfile),
            ("You have reached the maximum number of provisioning profiles. private-value", "", .profileLimit),
            ("private-value is invalid", "/data/relationships/certificates/data/0/id", .certificate),
            ("private-value is invalid", "/data/relationships/devices/data/0/id", .device),
            ("private-value is invalid", "/data/relationships/bundleId/data/id", .bundle),
            ("private-value", "/data/attributes/profileType", .profileType)
        ]
        for (detail, pointer, reason) in cases {
            let data = try payload(code: "ENTITY_ERROR.RELATIONSHIP.INVALID", detail: detail, pointer: pointer)
            let error = DeveloperProfileDiagnostics.rejection(status: 409, data: data)
            XCTAssertEqual(error, .profileRejected(409, reason))
            XCTAssertFalse(error?.localizedDescription.contains("private-value") ?? false)
            XCTAssertFalse(error?.localizedDescription.contains("secret@example.com") ?? false)
        }
    }

    func testMixedOrUnknownErrorsNeverAuthorizeRetry() throws {
        for extra in [
            ["detail": "There is already a current iOS Development profile for this App ID."],
            ["code": "UNKNOWN", "detail": "synthetic-private"]
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["errors": [
                ["code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "A profile with name 'test' already exists on this team.", "source": ["pointer": "/data/attributes/name"]] as [String: Any], extra
            ]])
            XCTAssertNotEqual(DeveloperProfileDiagnostics.rejection(status: 409, data: data), .profileRejected(409, .nameConflict))
        }
        let unknown = try payload(code: "secret@example.com", detail: "private-value", pointer: "/unknown/private-value")
        XCTAssertEqual(DeveloperProfileDiagnostics.rejection(status: 409, data: unknown), .profileRejected(409, .unknown))
    }

    func testMalformedOversizedAndOtherStatusesCannotBecomeNameConflicts() throws {
        for data in [Data(), Data("invalid".utf8), Data(repeating: 32, count: 65_537)] {
            XCTAssertNil(DeveloperProfileDiagnostics.rejection(status: 409, data: data))
        }
        let data = try payload(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", detail: "A profile with name 'test' already exists on this team.", pointer: "/data/attributes/name")
        XCTAssertNil(DeveloperProfileDiagnostics.rejection(status: 503, data: data))
    }

    private func payload(code: String, detail: String, pointer: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["errors": [["code": code, "detail": detail, "source": ["pointer": pointer]]]])
    }
}
