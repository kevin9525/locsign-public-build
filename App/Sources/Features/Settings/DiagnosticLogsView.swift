import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogsView: View {
    @State private var snapshot = ""
    @State private var loading = false
    @State private var message: String?
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("查看最近的运行记录，排查签名、安装或定位问题。导出内容与本页显示一致；点击刷新可读取新记录。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if loading && snapshot.isEmpty {
                    ProgressView("正在读取日志…").frame(maxWidth: .infinity)
                } else if snapshot.isEmpty && message == nil {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text", description: Text("使用签名或定位功能后，可回来查看运行记录。"))
                } else if !snapshot.isEmpty {
                    Text(snapshot)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                Button { exporting = true } label: {
                    Label("导出日志", systemImage: "square.and.arrow.up")
                }
                .disabled(loading || snapshot.isEmpty)
            }
        }
        .task { await refresh() }
        .fileExporter(isPresented: $exporting, document: DiagnosticLogDocument(text: snapshot),
                      contentType: .plainText, defaultFilename: "LocSign-diagnostics") { result in
            if case .failure = result { message = "日志导出失败，请重新选择保存位置。" }
        }
    }

    @MainActor
    private func refresh() async {
        guard !loading else { return }
        loading = true
        message = nil
        defer { loading = false }
        do { snapshot = try await AppLogger.snapshot() }
        catch {
            snapshot = ""
            message = "日志暂时无法读取，请稍后刷新重试。"
        }
    }
}

private struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
