import Foundation

enum PlistFraming {
    static let maximumPayload = 1_048_576

    static func encode(_ dict: [String: Any]) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        guard !body.isEmpty, body.count <= maximumPayload else {
            throw LocSignError.install("设备消息长度超出限制")
        }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    static func decode(_ frame: Data) throws -> [String: Any] {
        guard frame.count >= 4 else { throw LocSignError.install("设备消息帧不完整") }
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumPayload, frame.count == length + 4 else {
            throw LocSignError.install("设备消息帧长度无效")
        }
        guard let dict = try PropertyListSerialization.propertyList(from: Data(frame.dropFirst(4)), format: nil)
                as? [String: Any] else {
            throw LocSignError.install("设备消息不是 plist 字典")
        }
        return dict
    }

    static func write(_ dict: [String: Any], to stream: OutputStream) throws {
        let frame = try encode(dict)
        guard stream.streamStatus == .open || stream.streamStatus == .writing else {
            throw LocSignError.install("设备输出流未打开")
        }
        try frame.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < frame.count {
                let written = stream.write(base.assumingMemoryBound(to: UInt8.self).advanced(by: offset),
                                           maxLength: frame.count - offset)
                guard written > 0 else { throw LocSignError.install("写入设备消息失败") }
                offset += written
            }
        }
    }
}
