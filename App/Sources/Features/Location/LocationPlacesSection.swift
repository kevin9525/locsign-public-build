import SwiftUI

/// Favorites and recent places on the location page. Choosing a place only
/// fills the coordinate fields; the device changes only after "应用定位".
struct LocationPlacesSection: View {
    @ObservedObject var model: LocationViewModel
    @ObservedObject var places: LocationPlacesStore
    var onSelect: (SavedLocationPlace) -> Void
    @State private var favoriteName = ""
    @State private var addingFavorite = false
    @State private var renaming: SavedLocationPlace?
    @State private var renameText = ""
    @State private var confirmingClear = false
    @State private var saveError: String?

    var body: some View {
        DisclosureGroup("收藏与最近使用（\(places.favorites.count) / \(places.recents.count)）") {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    favoriteName = model.selectedPlaceName ?? ""
                    saveError = nil
                    addingFavorite = true
                } label: { Label("收藏当前坐标", systemImage: "star") }
                    .disabled(model.isBusy || places.loadError != nil)
                Text("收藏会保存坐标和坐标类型。点选地点只填入坐标，点“应用定位”后才发送到设备。长按地点可重命名或删除。")
                    .font(.caption).foregroundStyle(.secondary)

                Text("收藏").font(.headline)
                if places.favorites.isEmpty { Text("还没有收藏").font(.caption).foregroundStyle(.secondary) }
                ForEach(places.favorites) { place in
                    row(place) {
                        Button("重命名") { renameText = place.name; renaming = place }
                        Button("删除收藏", role: .destructive) { model.deleteFavorite(place) }
                    }
                }

                HStack {
                    Text("最近使用").font(.headline)
                    Spacer()
                    if !places.recents.isEmpty {
                        Button("清空", role: .destructive) { confirmingClear = true }.font(.caption)
                    }
                }
                if places.recents.isEmpty {
                    Text("成功应用定位后，会在这里保留最近 \(LocationPlacesStore.recentLimit) 个地点")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(places.recents) { place in
                    row(place) {
                        Button("从最近使用中删除", role: .destructive) { model.deleteRecent(place) }
                    }
                }
                if let message = model.placesMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                }
            }.padding(.top, 8)
        }
        .disabled(model.isBusy)
        .alert("收藏当前坐标", isPresented: $addingFavorite) {
            TextField("名称", text: $favoriteName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                do { try model.saveFavorite(name: favoriteName) }
                catch { saveError = error.localizedDescription }
            }
        } message: { Text("同一坐标、同一坐标类型只保存一次，再次收藏会更新名称。") }
        .alert("重命名收藏", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let place = renaming { model.renameFavorite(place, to: renameText) }
                renaming = nil
            }
        }
        .alert("清空最近使用？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { model.clearRecents() }
        } message: { Text("收藏不受影响。") }
        .alert("未能收藏", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private func row<Actions: View>(_ place: SavedLocationPlace, @ViewBuilder actions: () -> Actions) -> some View {
        Button { onSelect(place) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).frame(maxWidth: .infinity, alignment: .leading)
                Text(String(format: "%.6f, %.6f · %@", place.latitude, place.longitude,
                            place.coordinateSystem == .gcj02 ? "GCJ-02" : "WGS-84"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu { actions() }
    }
}
