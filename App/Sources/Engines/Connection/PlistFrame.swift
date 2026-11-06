import Foundation

enum PlistFrame {
    static let maximumPayload = 1_048_576

    static func encode(_ value: [String: Any]) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        guard !body.isEmpty, body.count <= maximumPayload else {
            throw LocSignError.install("设备响应长度超出限制")
        }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    struct Decoder {
        private var buffer = Data()

        mutating func append(_ data: Data) throws {
            // One full response and one network receive chunk at most.
            guard buffer.count + data.count <= PlistFrame.maximumPayload + 4 + 65_536 else {
                throw LocSignError.install("设备响应缓冲区超出限制")
            }
            buffer.append(data)
        }

        mutating func next() throws -> [String: Any]? {
            guard buffer.count >= 4 else { return nil }
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= PlistFrame.maximumPayload else {
                throw LocSignError.install("设备返回无效的数据帧长度")
            }
            guard buffer.count >= length + 4 else { return nil }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(length + 4))
            guard let response = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
                throw LocSignError.install("设备响应不是 plist 字典")
            }
            return response
        }
    }
}
