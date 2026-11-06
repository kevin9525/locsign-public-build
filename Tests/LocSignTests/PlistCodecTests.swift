import XCTest
@testable import LocSign

final class PlistCodecTests: XCTestCase {
    func testXMLRoundtrip() throws {
        let dict: [String: Any] = ["Name": "LocSign", "Count": 3, "Flag": true]
        let xml = try PlistCodec.encodeXML(dict)
        let back = try PlistCodec.decode(xml) as! [String: Any]
        XCTAssertEqual(back["Name"] as? String, "LocSign")
        XCTAssertEqual(back["Count"] as? Int, 3)
    }
    func testBPListDecode() throws {
        var data = Data("bplist00".utf8)
        data.append(Data(repeating: 0, count: 16))  // 最小假体，decode 应尝试 PropertyListSerialization
        XCTAssertThrowsError(try PlistCodec.decode(data)) // 损坏 bplist 应抛错而非崩溃
    }
}
