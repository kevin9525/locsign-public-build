import Foundation

enum AFCOperation: UInt64 {
    case status = 0x01
    case data = 0x02
    case removePath = 0x08
    case makeDirectory = 0x09
    case fileOpen = 0x0D
    case fileOpenResult = 0x0E
    case write = 0x10
    case fileClose = 0x14
}

struct AFCFrame {
    static let magic = Data("CFA6LPAA".utf8)
    static let headerLength = 40
    static let maximumPayload = 64 * 1024 * 1024

    let operation: AFCOperation
    let packetNumber: UInt64
    let payload: Data
    let thisLength: UInt64?

    func encoded() throws -> Data {
        let entireLength = UInt64(Self.headerLength + payload.count)
        let frameThisLength = thisLength ?? entireLength
        guard payload.count <= Self.maximumPayload,
              frameThisLength >= UInt64(Self.headerLength), frameThisLength <= entireLength else {
            throw LocSignError.install("AFC 数据包长度无效")
        }
        var result = Data()
        result.append(Self.magic)
        result.append(contentsOf: Self.le(UInt64(entireLength)))
        result.append(contentsOf: Self.le(frameThisLength))
        result.append(contentsOf: Self.le(packetNumber))
        result.append(contentsOf: Self.le(operation.rawValue))
        result.append(payload)
        return result
    }

    static func decode(_ data: Data) throws -> AFCFrame {
        guard data.count >= headerLength, data.prefix(8) == magic else {
            throw LocSignError.install("AFC 数据包头无效")
        }
        let entire = readUInt64(data, offset: 8)
        let thisLength = readUInt64(data, offset: 16)
        let packet = readUInt64(data, offset: 24)
        let operationRaw = readUInt64(data, offset: 32)
        guard entire >= UInt64(headerLength), entire <= UInt64(headerLength + maximumPayload),
              thisLength >= UInt64(headerLength), thisLength <= entire,
              data.count == Int(entire), let operation = AFCOperation(rawValue: operationRaw) else {
            throw LocSignError.install("AFC 数据包长度或操作码无效")
        }
        return AFCFrame(operation: operation, packetNumber: packet,
                        payload: Data(data.dropFirst(headerLength)),
                        thisLength: thisLength == entire ? nil : thisLength)
    }

    static func openWrite(path: String, packetNumber: UInt64) -> AFCFrame {
        var payload = Data()
        payload.append(contentsOf: Self.le(UInt64(0x03)))
        payload.append(contentsOf: Data(path.utf8))
        payload.append(0)
        return AFCFrame(operation: .fileOpen, packetNumber: packetNumber, payload: payload, thisLength: nil)
    }

    static func write(handle: UInt64, data: Data, packetNumber: UInt64) -> AFCFrame {
        var payload = Data(Self.le(handle))
        payload.append(data)
        return AFCFrame(operation: .write, packetNumber: packetNumber, payload: payload,
                        thisLength: UInt64(headerLength + 8))
    }

    static func close(handle: UInt64, packetNumber: UInt64) -> AFCFrame {
        AFCFrame(operation: .fileClose, packetNumber: packetNumber,
                 payload: Data(Self.le(handle)), thisLength: nil)
    }

    static func remove(path: String, packetNumber: UInt64) -> AFCFrame {
        AFCFrame(operation: .removePath, packetNumber: packetNumber,
                 payload: Data(path.utf8) + Data([0]), thisLength: nil)
    }

    static func makeDirectory(path: String, packetNumber: UInt64) -> AFCFrame {
        AFCFrame(operation: .makeDirectory, packetNumber: packetNumber,
                 payload: Data(path.utf8) + Data([0]), thisLength: nil)
    }

    static func statusCode(from response: AFCFrame) throws -> UInt64 {
        guard response.operation == .status, response.payload.count == 8 else {
            throw LocSignError.install("AFC 服务返回了无效状态")
        }
        return readUInt64(response.payload, offset: 0)
    }

    static func openedHandle(from response: AFCFrame) throws -> UInt64 {
        guard (response.operation == .data || response.operation == .fileOpenResult),
              response.payload.count == 8 else {
            throw LocSignError.install("AFC 服务未返回文件句柄")
        }
        return readUInt64(response.payload, offset: 0)
    }

    private static func le(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }
}

struct InstallationProxyProtocol {
    static func installRequest(packagePath: String, options: [String: Any] = [:]) -> [String: Any] {
        ["Command": "Install", "PackagePath": packagePath, "ClientOptions": options]
    }

    static func progress(from response: [String: Any]) throws -> (percent: Double?, complete: Bool) {
        if let error = response["Error"] as? String {
            let detail = response["ErrorDescription"] as? String ?? ""
            throw LocSignError.install(detail.isEmpty ? error : "\(error)：\(detail)")
        }
        guard let status = response["Status"] as? String, !status.isEmpty else {
            throw LocSignError.install("安装服务返回了不完整的进度响应")
        }
        let percent = (response["PercentComplete"] as? NSNumber)?.doubleValue
        guard percent == nil || (0...100).contains(percent!) else {
            throw LocSignError.install("安装服务返回无效进度")
        }
        return (percent, status == "Complete")
    }
}
