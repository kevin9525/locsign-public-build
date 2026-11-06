import XCTest
@testable import LocSign

final class PlistFrameTests: XCTestCase {
    func testHeaderUsesNetworkByteOrder() throws {
        let frame = try PlistFrame.encode(["Request": "QueryType"])
        let bytes = Array(frame.prefix(4))
        let length = bytes.reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, frame.count - 4)
        let payload = try PropertyListSerialization.propertyList(from: Data(frame.dropFirst(4)), format: nil)
        XCTAssertEqual((payload as? [String: String])?["Request"], "QueryType")
    }

    func testIncrementalFramePreservesFollowingResponse() throws {
        let a = try PlistFrame.encode(["Type": "com.apple.mobile.lockdown"])
        let b = try PlistFrame.encode(["Value": "18.7.3"])
        var decoder = PlistFrame.Decoder()
        try decoder.append(Data(a.prefix(2)))
        XCTAssertNil(try decoder.next())
        try decoder.append(Data(a.dropFirst(2)) + b)
        XCTAssertEqual(try decoder.next()?["Type"] as? String, "com.apple.mobile.lockdown")
        XCTAssertEqual(try decoder.next()?["Value"] as? String, "18.7.3")
        XCTAssertNil(try decoder.next())
    }

    func testEmptyAndOversizedFramesAreRejectedBeforePayloadArrives() throws {
        for header in [Data([0, 0, 0, 0]), Data([127, 255, 255, 255])] {
            var decoder = PlistFrame.Decoder()
            try decoder.append(header)
            XCTAssertThrowsError(try decoder.next())
        }
    }

    func testNonDictionaryPayloadIsRejected() throws {
        let body = try PropertyListSerialization.data(fromPropertyList: ["unexpected"], format: .xml, options: 0)
        var size = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &size) { Data($0) }
        var decoder = PlistFrame.Decoder()
        try decoder.append(header + body)
        XCTAssertThrowsError(try decoder.next())
    }
}
