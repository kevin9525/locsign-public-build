import Foundation
import ZIPFoundation

func isMachO(_ url: URL) -> Bool {
    guard let fh = FileHandle(forReadingAtPath: url.path) else { return false }
    defer { try? fh.close() }
    guard let magic = try? fh.read(upToCount: 4) else { return false }
    let m = [UInt8](magic)
    // MH_MAGIC_64 / MH_CIGAM_64 / FAT_MAGIC（瘦/胖包都算）
    return m.count == 4 && ((m[0], m[1], m[2], m[3]) == (0xcf, 0xfa, 0xed, 0xce)
        || (m[0], m[1], m[2], m[3]) == (0xce, 0xfa, 0xed, 0xcf)
        || (m[0], m[1], m[2], m[3]) == (0xca, 0xfe, 0xba, 0xbe)
        || (m[0], m[1], m[2], m[3]) == (0xbe, 0xba, 0xfe, 0xca))
}

enum IPAPacker {
    /// 解包 IPA，返回 .app 目录 URL
    static func unpack(_ ipaURL: URL, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: ipaURL, to: dir)
        let payload = dir.appendingPathComponent("Payload")
        guard let app = try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw LocSignError.signing("IPA 内找不到 .app") }
        return app
    }

    /// 从 appURL 的父目录（即 Payload 所在层）重新打包为 IPA
    static func repack(appURL: URL, outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.zipItem(at: appURL.deletingLastPathComponent(), to: outputURL)
    }

    /// 测试用薄包装：把指定目录打成 zip（目录本身为 zip 根）
    static func makeZip(fromDirectory dir: URL, to outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.zipItem(at: dir, to: outputURL)
    }
}
