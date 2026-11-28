import Foundation

struct IPAImportPreview: Sendable, Equatable {
    struct Extension: Sendable, Equatable, Identifiable {
        let path: String
        let name: String
        let bundleID: String?
        var id: String { path }
    }
    let name: String
    let bundleID: String?
    let version: String?
    let build: String?
    let minimumOSVersion: String?
    let fileSize: Int64
    let extensions: [Extension]
    let automaticSigningIssue: String?
}

struct IPAImportPreviewInspector: Sendable {
    func inspect(_ url: URL) throws -> IPAImportPreview {
        // Interface scaffold for the first behavioral test run.
        throw LocSignError.signing("尚未读取 IPA 预览")
    }
}
