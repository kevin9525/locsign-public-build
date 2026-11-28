import SwiftUI
import UniformTypeIdentifiers

struct LocationPlacesManagementView: View {
    @ObservedObject var model: LocationViewModel
    @ObservedObject var settings: InstallationSettings
    @ObservedObject var places: LocationPlacesStore
    var onSelect: (SavedLocationPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sort: LocationPlacesSort = .saved
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: LocationPlacesBackupDocument?
    @State private var importTask: Task<Void, Never>?
    @State private var isReading = false
    @State private var preview: LocationPlacesImportPreview?
    @State private var showingPreview = false
    @State private var renameTarget: SavedLocationPlace?
    @State private var renameText = ""
    @State private var message: String?

    private var locked: Bool { model.isBusy || settings.operationID != nil || isReading }
    private var matches: [SavedLocationPlace] { places.matchingFavorites(query: query, sort: sort) }

    var body: some View {
        List {
            Section {
                Picker("排列方式", selection: $sort) {
                    ForEach(LocationPlacesSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: { Text("搜索和排序只改变显示。点选地点只填入坐标，返回后点“应用定位”才发送到设备。") }
            if let issue = message ?? places.loadError ?? model.placesMessage {
                Section { Text(issue).font(.footnote).textSelection(.enabled) }
            }
            if isReading {
                Section {
                    HStack { ProgressView(); Text("正在读取收藏备份…") }
                    Button("取消读取", role: .cancel) { importTask?.cancel() }
                }
            }
            Section("收藏（\(matches.count)/\(places.favorites.count)）") {
                if matches.isEmpty {
                    Text(places.favorites.isEmpty ? "还没有收藏。可返回收藏当前坐标，或导入备份。" : "没有找到匹配的收藏。")
                        .foregroundStyle(.secondary)
                }
                ForEach(matches) { place in
                    Button {
                        guard !locked else { return }
                        onSelect(place)
                        dismiss()
                    } label: { placeLabel(place) }
                        .disabled(locked)
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                guard !locked else { return }
                                model.deleteFavorite(place)
                            }.disabled(locked)
                            Button("重命名") {
                                renameTarget = place
                                renameText = place.name
                            }.tint(.blue).disabled(locked)
                        }
                }
            }
        }
        .navigationTitle("收藏管理")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索收藏名称")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("导入收藏", systemImage: "square.and.arrow.down") { importing = true }
                    Button("导出全部收藏", systemImage: "square.and.arrow.up", action: exportFavorites)
                } label: { Label("备份", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(locked || places.loadError != nil)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): readBackup(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = "无法打开备份，请重新选择文件。" }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "LocSign-favorites") { result in
            switch result {
            case .success: message = "已导出全部收藏。"
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = "导出未完成，请重新选择保存位置。" }
            }
            exportDocument = nil
        }
        .sheet(isPresented: $showingPreview, onDismiss: { preview = nil }) {
            if let preview { importPreview(preview) }
        }
        .alert("重命名收藏", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let target = renameTarget, !locked { model.renameFavorite(target, to: renameText) }
                renameTarget = nil
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    private func placeLabel(_ place: SavedLocationPlace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.name).foregroundStyle(.primary)
            Text(String(format: "%.6f, %.6f", place.latitude, place.longitude))
                .font(.caption).foregroundStyle(.secondary)
            Text(place.coordinateSystem.title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func importPreview(_ preview: LocationPlacesImportPreview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("备份中的收藏", value: "\(preview.totalCount) 个")
                    LabeledContent("新增", value: "\(preview.additions.count) 个")
                    LabeledContent("跳过重复", value: "\(preview.duplicateCount) 个")
                } footer: {
                    Text("同坐标、同坐标类型保留本地记录；文件内重复地点保留第一条。最近使用和当前定位不受影响。")
                }
                Section("将新增的收藏") {
                    if preview.additions.isEmpty { Text("没有需要新增的收藏。") }
                    ForEach(preview.additions.prefix(20)) { placeLabel($0) }
                    if preview.additions.count > 20 {
                        Text("另有 \(preview.additions.count - 20) 个收藏，确认后一起导入。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { showingPreview = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认导入") {
                        do {
                            let count = try model.importPlaces(preview)
                            message = "已导入 \(count) 个收藏，跳过 \(preview.duplicateCount) 个重复地点。"
                        } catch { message = error.localizedDescription }
                        showingPreview = false
                    }
                    .disabled(locked || preview.additions.isEmpty)
                }
            }
        }
    }

    private func readBackup(_ url: URL) {
        guard !locked, places.loadError == nil else { return }
        isReading = true
        message = nil
        preview = nil
        importTask = Task { @MainActor in
            defer { isReading = false; importTask = nil }
            do {
                let data = try await LocationPlacesBackup.read(url)
                try Task.checkCancellation()
                preview = try model.previewPlacesImport(data)
                showingPreview = true
            } catch is CancellationError {
                message = "已取消读取，收藏未改变。"
            } catch { message = error.localizedDescription }
        }
    }

    private func exportFavorites() {
        guard !locked else { return }
        do {
            exportDocument = LocationPlacesBackupDocument(data: try places.exportFavorites())
            message = nil
            exporting = true
        } catch { message = error.localizedDescription }
    }
}

private struct LocationPlacesBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= LocationPlacesBackup.maximumBytes else {
            throw LocationPlacesBackupError.tooLarge
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
