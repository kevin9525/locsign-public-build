import Foundation

/// All file access, including snapshots, runs on the same queue. A snapshot
/// therefore includes every log entry submitted before it was requested.
final class DiagnosticLogStore: @unchecked Sendable {
    private let fileURL: URL
    private let maximumFileBytes: Int
    private let maximumSnapshotBytes: Int
    private let queue = DispatchQueue(label: "com.locsign.diagnostic-log", qos: .utility)
    private var lastWriteError: Error?

    init(fileURL: URL, maximumFileBytes: Int = 512 * 1024, maximumSnapshotBytes: Int = 128 * 1024) {
        precondition(maximumFileBytes >= 128 && maximumSnapshotBytes >= 64 && maximumSnapshotBytes <= maximumFileBytes)
        self.fileURL = fileURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumSnapshotBytes = maximumSnapshotBytes
    }

    func append(_ entry: String) {
        queue.async {
            do {
                try self.write(entry)
                self.lastWriteError = nil
            } catch {
                self.lastWriteError = error
            }
        }
    }

    func snapshot() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if let error = self.lastWriteError { throw error }
                    // Redact before selecting the smaller display/export tail,
                    // so multi-line private keys are not split by that limit.
                    let stored = try self.readTail(maximumBytes: self.maximumFileBytes)
                    let redacted = Self.redactStoredText(String(decoding: stored, as: UTF8.self))
                    let result = Self.completeTail(Data(redacted.utf8), maximumBytes: self.maximumSnapshotBytes)
                    continuation.resume(returning: String(decoding: result, as: UTF8.self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func write(_ entry: String) throws {
        // Redact the entire input before truncating or flattening it; a secret
        // marker at the end must still hide the beginning of a large message.
        let safe = ProvisioningRedaction.redact(entry)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ↵ ")
        let record = Self.record(safe, maximumBytes: min(16 * 1024, min(maximumFileBytes / 2, maximumSnapshotBytes)))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let size = try fileSize() else {
            try record.write(to: fileURL, options: .atomic)
            return
        }
        let separator = try missingSeparator(size: size)
        if size > UInt64(maximumFileBytes - record.count - separator.count) {
            let previous = try readTail(maximumBytes: maximumFileBytes)
            var retained = Self.completeTail(Data(Self.redactStoredText(String(decoding: previous, as: UTF8.self)).utf8),
                                             maximumBytes: maximumFileBytes / 2)
            if !retained.isEmpty && retained.last != 10 { retained.append(10) }
            retained.append(record)
            try Self.completeTail(retained, maximumBytes: maximumFileBytes).write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: separator + record)
        }
    }

    private func missingSeparator(size: UInt64) throws -> Data {
        guard size > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: size - 1)
        return try handle.read(upToCount: 1)?.last == 10 ? Data() : Data([10])
    }

    private func fileSize() throws -> UInt64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
            return size.uint64Value
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func readTail(maximumBytes: Int) throws -> Data {
        guard let size = try fileSize() else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        // Include the preceding byte to distinguish a line boundary from a
        // partial UTF-8 character or partial record in an old, unbounded file.
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try handle.seek(toOffset: offset > 0 ? offset - 1 : 0)
        var data = try handle.read(upToCount: maximumBytes + (offset > 0 ? 1 : 0)) ?? Data()
        if offset > 0 && !data.isEmpty {
            let preceding = data.removeFirst()
            if preceding != 10 {
                guard let newline = data.firstIndex(of: 10) else { return Data() }
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            // A legacy multi-line message may start before the bounded read,
            // including an unfinished PEM block. Resume only at a complete
            // AppLogger record, not at an arbitrary continuation line.
            let text = String(decoding: data, as: UTF8.self)
            guard let firstRecord = text.range(
                of: #"(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} \[(?:DEBUG|INFO|WARN|ERROR)\] "#,
                options: .regularExpression) else { return Data() }
            data = Data(text[firstRecord.lowerBound...].utf8)
        }
        return data
    }

    private static func record(_ text: String, maximumBytes: Int) -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count + 1 > maximumBytes else { return bytes + Data([10]) }
        let marker = Data("…[内容过长，已截断]\n".utf8)
        var prefix = Data(bytes.prefix(maximumBytes - marker.count))
        while String(data: prefix, encoding: .utf8) == nil && !prefix.isEmpty { prefix.removeLast() }
        return prefix + marker
    }

    private static func completeTail(_ data: Data, maximumBytes: Int) -> Data {
        guard data.count > maximumBytes else { return data }
        let start = data.index(data.endIndex, offsetBy: -maximumBytes)
        if data[data.index(before: start)] == 10 { return Data(data[start...]) }
        guard let newline = data[start...].firstIndex(of: 10) else { return Data() }
        return Data(data.suffix(from: data.index(after: newline)))
    }

    private static func redactStoredText(_ text: String) -> String {
        var safe = text.replacingOccurrences(
            of: #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#,
            with: "[敏感内容已隐藏]", options: .regularExpression)
        // A bounded read of a legacy file can begin inside a PEM block.
        safe = safe.replacingOccurrences(of: #"(?s)\A.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
                                         with: "[敏感内容已隐藏]", options: .regularExpression)
        return safe.components(separatedBy: "\n").map(ProvisioningRedaction.redact).joined(separator: "\n")
    }
}
