import Foundation

enum AppLogger {
    enum Level: String { case debug, info, warn, error }
    private static let queue = DispatchQueue(label: "applog")
    private static var buffer: [String] = []
    private static var logURL: URL? {
        guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return doc.appendingPathComponent("logs/app.log")
    }
    static func log(_ level: Level, _ tag: String, _ message: String) {
        let line = "\(Date()) [\(level.rawValue.uppercased())] \(tag): \(message)"
        queue.async {
            buffer.append(line)
            if buffer.count > 2000 { buffer.removeFirst(buffer.count - 2000) }
            if let url = logURL {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.appendLineTo(file: url)
            }
        }
    }
}

extension String {
    func appendLineTo(file: URL) throws {
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data((self + "\n").utf8)); try? handle.close()
        } else {
            try (self + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
