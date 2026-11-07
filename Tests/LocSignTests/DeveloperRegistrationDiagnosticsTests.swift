import XCTest
@testable import LocSign

final class DeveloperRegistrationDiagnosticsTests: XCTestCase {
    func testUnknownMalformedAndOversizedErrorsRemainUnclassified() throws {
        for data in [Data(), Data("not JSON".utf8), Data(repeating: 32, count: 65_537),
                     try JSONSerialization.data(withJSONObject: ["errors": [["code": "secret@example.com", "detail": "private server response"]]])] {
            XCTAssertNil(DeveloperRegistrationDiagnostics.rejection(status: 409, data: data))
        }
    }

    func testRegistrationLimitTakesPriorityWithoutRetainingServerStrings() throws {
        let data = try JSONSerialization.data(withJSONObject: ["errors": [
            ["detail": "An App ID with Identifier private-value is not available"],
            ["detail": "You may register a maximum of 10 App IDs every 7 days; private-value"]
        ]])
        XCTAssertEqual(DeveloperRegistrationDiagnostics.rejection(status: 409, data: data), .registrationRejected(409, .registrationLimit))
        XCTAssertNil(DeveloperRegistrationDiagnostics.rejection(status: 503, data: data))
        XCTAssertFalse(String(describing: DeveloperRegistrationDiagnostics.rejection(status: 409, data: data)).contains("private-value"))
    }
}
