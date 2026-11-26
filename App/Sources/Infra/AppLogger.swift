import Foundation

enum AppLogger {
    enum Level: String { case debug, info, warn, error }
    private static let store: DiagnosticLogStore? = {
        guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return DiagnosticLogStore(fileURL: doc.appendingPathComponent("logs/app.log"))
    }()

    static func log(_ level: Level, _ tag: String, _ message: String) {
        store?.append("\(Date()) [\(level.rawValue.uppercased())] \(ProvisioningRedaction.redact(tag + ": " + message))")
    }

    static func snapshot() async throws -> String {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        return try await store.snapshot()
    }
}
