import SwiftUI

/// Favorites and recent places as horizontal chips. Choosing a place only
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

    private var canFavorite: Bool {
        !model.isBusy && places.loadError == nil && !model.latitude.isEmpty && !model.longitude.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("常用地点").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    favoriteName = model.selectedPlaceName ?? ""
                    saveError = nil
                    addingFavorite = true
                } label: { Label("收藏当前", systemImage: "star") }
                    .font(.subheadline)
                    .disabled(!canFavorite)
            }
            if places.favorites.isEmpty && places.recents.isEmpty {
                Text("收藏的地点和最近应用过的位置会显示在这里。点一下只填入坐标，点“应用定位”后才会改变手机定位。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(places.favorites) { place in
                            chip(place, systemImage: "star.fill", tint: .yellow)
                                .contextMenu {
                                    Button("重命名") { renameText = place.name; renaming = place }
                                    Button("删除收藏", role: .destructive) { model.deleteFavorite(place) }
                                }
                        }
                        ForEach(places.recents) { place in
                            chip(place, systemImage: "clock", tint: .secondary)
                                .contextMenu {
                                    Button("从最近使用中删除", role: .destructive) { model.deleteRecent(place) }
                                    Button("清空最近使用", role: .destructive) { confirmingClear = true }
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("长按地点可重命名或删除；最近使用保留最近 \(LocationPlacesStore.recentLimit) 个。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let message = model.placesMessage {
                Text(message).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
            }
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

    private func chip(_ place: SavedLocationPlace, systemImage: String, tint: Color) -> some View {
        let selected = isSelected(place)
        return Button { onSelect(place) } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.caption).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(place.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                    Text(place.coordinateSystem == .gcj02 ? "大陆地图坐标" : "GPS 坐标")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 180, alignment: .leading)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
            .overlay(Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ place: SavedLocationPlace) -> Bool {
        guard let latitude = Double(model.latitude.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(model.longitude.trimmingCharacters(in: .whitespaces)),
              let point = try? LocationCoordinate(latitude: latitude, longitude: longitude) else { return false }
        return place.matches(point, system: model.inputSystem)
    }
}
