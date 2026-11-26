import SwiftUI
import MapKit

/// Virtual location: search or tap the map, then apply. Less common options
/// (coordinate type, manual input, connection mode) are under "高级".
struct LocationView: View {
    @ObservedObject var model: LocationViewModel
    @ObservedObject var settings: InstallationSettings
    @State private var position: MapCameraPosition = .automatic
    @State private var showingAdvanced = false
    @State private var centered = false
    @FocusState private var searchFocused: Bool

    private var locked: Bool { model.isBusy || settings.operationID != nil }
    private var applied: Bool {
        model.selectionState == .accepted
    }
    private var statusIcon: String {
        if model.isBusy { return "hourglass" }
        if model.error != nil { return "exclamationmark.triangle.fill" }
        return applied ? "location.fill" : "location"
    }
    private var statusColor: Color {
        if model.error != nil { return .red }
        if applied { return .green }
        return model.selectionState == .pending || model.selectionState == .unconfirmed ? .orange : .secondary
    }
    private var placeTitle: String {
        if let name = model.selectedPlaceName { return name }
        if model.latitude.isEmpty || model.longitude.isEmpty { return "尚未选择位置" }
        return "\(model.latitude), \(model.longitude)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    searchBar
                    if !model.searchResults.isEmpty { searchResultsList }
                    map
                    LocationPlacesSection(model: model, places: model.places) { place in
                        model.selectPlace(place)
                        focus(on: model.selected)
                    }
                    if model.requiresCellularRestore { cellularRestoreCard }
                    advanced
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("虚拟定位")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !centered { centered = true; focus(on: model.selected) }
            }
            .onChange(of: settings.host) { _, _ in Task { await model.settingsChanged() } }
            .onChange(of: settings.pairing) { _, _ in Task { await model.settingsChanged() } }
        }
    }

    // MARK: Search and map

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索城市、地址或地点", text: $model.searchText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit(search)
                if !model.searchText.isEmpty {
                    Button { clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
            if model.isSearching {
                ProgressView()
            } else {
                Button("搜索", action: search)
                    .disabled(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var searchResultsList: some View {
        let items = Array(model.searchResults.prefix(8))
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    let point = item.placemark.coordinate
                    model.selectSearchCoordinate(point, countryCode: item.placemark.isoCountryCode, name: item.name)
                    focus(on: model.selected ?? point)
                    clearSearch()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "地点").foregroundStyle(.primary)
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
                if index < items.count - 1 { Divider().padding(.leading, 12) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let selected = model.selected {
                    Marker(model.selectedPlaceName ?? "所选位置", coordinate: selected)
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) { model.selectMapCoordinate(coordinate) }
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottomLeading) {
            Text("点击地图选点")
                .font(.caption2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
    }

    // MARK: Bottom action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon).font(.title3).foregroundStyle(statusColor).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前选点").font(.caption2).foregroundStyle(.secondary)
                    Text(placeTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(model.isBusy ? model.status : model.selectionMessage)
                        .font(.caption).foregroundStyle(model.isBusy ? Color.secondary : statusColor)
                }
                Spacer(minLength: 0)
                if model.isBusy {
                    Button("取消", role: .cancel, action: model.cancel).font(.subheadline)
                }
            }
            if let accepted = model.lastAcceptedLocation {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("上次设备接受：\(accepted.title)").lineLimit(1)
                    Spacer(minLength: 0)
                    Text(accepted.acceptedAt, style: .time)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !model.isBusy {
                Text(model.status).font(.caption2).foregroundStyle(.secondary)
            }
            if let assist = model.networkAssistStatus {
                Text(assist).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if model.isBusy && model.networkAssistStatus != nil {
                Text("取消后仍会等待当前快捷指令返回，并尝试恢复蜂窝数据。").font(.caption2).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            if let notice = model.restorationNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 10) {
                Button(action: model.apply) {
                    Label(model.isBusy ? "处理中…" : "应用定位", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectionState == .empty || model.selectionState == .invalid)
                Button(action: model.restore) {
                    Label("恢复真实", systemImage: "location.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .disabled(locked)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var cellularRestoreCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("蜂窝数据恢复待确认", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(model.cellularRestoreWarning ?? "蜂窝数据恢复待确认。如流程被中断，请先在“快捷指令”App 中停止仍在运行的指令，再运行恢复快捷指令，或在系统设置中开启蜂窝数据。")
                .font(.footnote)
            Button("恢复蜂窝数据", action: model.restoreCellularData)
                .buttonStyle(.borderedProminent)
                .disabled(locked)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Advanced

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showingAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                Text("地图区域").font(.subheadline.weight(.semibold))
                Picker("地图区域", selection: Binding(get: { model.mapRegion }, set: model.setMapRegion)) {
                    ForEach(LocationMapRegion.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(locked)
                Picker("输入坐标类型", selection: Binding(get: { model.inputSystem }, set: model.setInputSystem)) {
                    ForEach(LocationCoordinateSystem.allCases) { Text($0.title).tag($0) }
                }
                .disabled(locked)
                Text("搜索结果会自动选择坐标类型；大陆地图选点会纠偏后发送给设备。粘贴 GPS 经纬度时请选择 WGS-84。地图区域只决定选点和显示方式。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("纬度（-90～90）", text: $model.latitude).textFieldStyle(.roundedBorder)
                    TextField("经度（-180～180）", text: $model.longitude).textFieldStyle(.roundedBorder)
                }
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(locked)
                Button("在地图上显示坐标") {
                    model.selectManual()
                    focus(on: model.selected)
                }
                .disabled(locked)

                Divider()

                Text("连接方式").font(.subheadline.weight(.semibold))
                Picker("定位连接方式", selection: Binding(get: { model.connectionMode }, set: model.setConnectionMode)) {
                    ForEach(LocationConnectionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(locked || model.requiresCellularRestore)
                Text(model.connectionMode == .assisted
                     ? "应用和恢复都会先暂时关闭蜂窝数据，完成后尝试恢复。已记住此方式；请保持 LocalDevVPN 开启。"
                     : "应用和恢复都会直接连接设备。连接 Wi-Fi 时通常可用；关闭 Wi-Fi 后连接失败，可选择“无 Wi-Fi 辅助”。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("无 Wi-Fi 辅助：快捷指令设置") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("适用于 LocalDevVPN 已开启、但使用蜂窝数据时无法连接设备的情况。将暂时关闭蜂窝数据，等待设备服务后执行定位，再尝试开启蜂窝数据。首次准备或手机重启后，请先连接 Wi-Fi 成功应用一次定位。")
                        Text("首次设置：在 iOS“快捷指令”App 中创建以下两条快捷指令。每条只需添加一个“设置蜂窝数据”动作；不要使用“切换”，不要添加“打开 App”动作。")
                        Text("① LocSign关闭蜂窝数据\n设置蜂窝数据 → 关闭\n\n② LocSign开启蜂窝数据\n设置蜂窝数据 → 打开")
                            .textSelection(.enabled)
                        Text("名称须完全一致。运行时允许快捷指令执行，完成后会自动返回 LocSign；恢复数据后连接可能中断。")
                    }
                    .font(.footnote)
                    .padding(.top, 6)
                }
                .font(.subheadline)

                Divider()

                Text("首次使用请开启 iOS 开发者模式并重启确认，保持设备解锁和 LocalDevVPN 开启。首次准备会联网向 Apple 申请开发者镜像个性化。系统可能在后台挂起定位连接；其他 App 刷新位置可能有延迟。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            Label("高级：坐标类型、手动输入、连接方式", systemImage: "slider.horizontal.3")
                .font(.subheadline)
        }
    }

    // MARK: Helpers

    private func search() {
        searchFocused = false
        Task { await model.searchAddress() }
    }

    private func clearSearch() {
        model.searchText = ""
        Task { await model.searchAddress() }
    }

    private func focus(on point: CLLocationCoordinate2D?) {
        guard let point else { return }
        position = .region(.init(center: point, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    }
}
