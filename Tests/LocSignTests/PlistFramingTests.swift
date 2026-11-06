import XCTest
@testable import LocSign

final class PlistFramingTests: XCTestCase {
    func testRoundTripsXMLPlistFrame() throws {
        let frame = try PlistFraming.encode(["Request": "QueryType", "Number": 7])
        XCTAssertTrue(String(data: frame.dropFirst(4), encoding: .utf8)?.hasPrefix("<?xml") == true)
        let result = try PlistFraming.decode(frame)
        XCTAssertEqual(result["Request"] as? String, "QueryType")
        XCTAssertEqual(result["Number"] as? Int, 7)
    }

    func testRejectsTrailingBytesAndNonDictionaryPayload() throws {
        let frame = try PlistFraming.encode(["Request": "QueryType"])
        XCTAssertThrowsError(try PlistFraming.decode(frame + Data([0])))

        let body = try PropertyListSerialization.data(fromPropertyList: ["value"], format: .binary, options: 0)
        var length = UInt32(body.count).bigEndian
        let invalid = withUnsafeBytes(of: &length) { Data($0) } + body
        XCTAssertThrowsError(try PlistFraming.decode(invalid))
    }
}
