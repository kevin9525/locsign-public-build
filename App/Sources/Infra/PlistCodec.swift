import Foundation

enum PlistCodec {
    static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, format: nil)
    }
    static func encodeXML(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
    static func encodeBinary(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }
}
