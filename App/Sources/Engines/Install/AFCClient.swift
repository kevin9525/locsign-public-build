import Foundation

final class AFCClient {
    private let connection: any DeviceServiceTransport
    private var packetNumber: UInt64 = 0
    private let operationLock = NSLock()

    init(connection: any DeviceServiceTransport) { self.connection = connection }

    func makeDirectory(path: String) async throws {
        guard (path == "/PublicStaging" || path.hasPrefix("/PublicStaging/")), !path.contains("..") else {
            throw LocSignError.install("安装暂存目录无效")
        }
        let response = try await connection.exchangeAFC(AFCFrame.makeDirectory(path: path, packetNumber: nextPacket()))
        let status = try AFCFrame.statusCode(from: response)
        guard status == 0 || status == 16 else {
            throw LocSignError.install("无法创建安装暂存目录（状态 \(status)）")
        }
    }

    func uploadFile(localURL: URL, remotePath: String,
                    progress: @Sendable (Double) async -> Void = { _ in }) async throws {
        guard remotePath.hasPrefix("/PublicStaging/"), !remotePath.contains("..") else {
            throw LocSignError.install("安装暂存路径无效")
        }
        let open = try await connection.exchangeAFC(AFCFrame.openWrite(path: remotePath, packetNumber: nextPacket()))
        let handle = try AFCFrame.openedHandle(from: open)
        do {
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            let size = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            var sent = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 512 * 1024) ?? Data()
                if chunk.isEmpty { break }
                let response = try await connection.exchangeAFC(
                    AFCFrame.write(handle: handle, data: chunk, packetNumber: nextPacket()))
                try checkStatus(response)
                sent += chunk.count
                await progress(size > 0 ? Double(sent) / Double(size) : 1)
            }
            try await requireSuccess(AFCFrame.close(handle: handle, packetNumber: nextPacket()))
        } catch {
            _ = try? await connection.exchangeAFC(AFCFrame.close(handle: handle, packetNumber: nextPacket()))
            _ = try? await connection.exchangeAFC(AFCFrame.remove(path: remotePath, packetNumber: nextPacket()))
            throw error
        }
    }

    func removePath(_ remotePath: String) async throws {
        guard remotePath.hasPrefix("/PublicStaging/"), !remotePath.contains("..") else {
            throw LocSignError.install("安装暂存路径无效")
        }
        try await requireSuccess(AFCFrame.remove(path: remotePath, packetNumber: nextPacket()))
    }

    private func requireSuccess(_ frame: AFCFrame) async throws {
        try checkStatus(await connection.exchangeAFC(frame))
    }

    private func checkStatus(_ response: AFCFrame) throws {
        let status = try AFCFrame.statusCode(from: response)
        guard status == 0 else { throw LocSignError.install("AFC 文件操作失败（状态 \(status)）") }
    }

    private func nextPacket() -> UInt64 {
        operationLock.lock(); defer { operationLock.unlock() }
        defer { packetNumber &+= 1 }
        return packetNumber
    }
}
