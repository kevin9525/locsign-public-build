import SwiftUI
import MapKit

struct LocationView: View {
    @ObservedObject var model: LocationViewModel
    @ObservedObject var settings: InstallationSettings
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("地图区域", selection: Binding(get: { model.mapRegion }, set: model.setMapRegion)) {
                        ForEach(LocationMapRegion.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.isBusy)
                    MapReader { proxy in
                        Map(position: $position) {
                            if let selected = model.selected {
                                Marker("所选坐标", coordinate: selected)
                            }
                        }
                        .mapControls { MapCompass(); MapScaleView() }
                        .onTapGesture { point in
                            if let coordinate = proxy.convert(point, from: .local) { model.selectMapCoordinate(coordinate) }
                        }
                    }.frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 16))
                    HStack {
                        TextField("搜索城市、地址或地点", text: $model.searchText)
                            .textFieldStyle(.roundedBorder).onSubmit { Task { await model.searchAddress() } }
                        Button("搜索") { Task { await model.searchAddress() } }.disabled(model.isSearching)
                    }
                    if model.isSearching { ProgressView("正在搜索…") }
                    ForEach(Array(model.searchResults.enumerated()), id: \.offset) { _, item in
                        Button {
                            let point = item.placemark.coordinate
                            model.selectSearchCoordinate(point, countryCode: item.placemark.isoCountryCode)
                            position = .region(.init(center: point, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "地点")
                                Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Picker("输入坐标类型", selection: Binding(get: { model.inputSystem }, set: model.setInputSystem)) {
                        ForEach(LocationCoordinateSystem.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.isBusy)
                    Text("搜索结果会自动选择坐标类型。大陆地图选点会纠偏后发送给设备；粘贴 GPS 经纬度时请选择 WGS-84。地图区域仅决定选点和显示方式，不会切换地图提供方。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("纬度 −90…90", text: $model.latitude).textFieldStyle(.roundedBorder)
                        TextField("经度 −180…180", text: $model.longitude).textFieldStyle(.roundedBorder)
                    }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.isBusy)
                    Button("在地图上显示坐标") {
                        model.selectManual()
                        if let point = model.selected { position = .region(.init(center: point, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))) }
                    }
                    HStack {
                        Button("应用定位", action: model.apply).buttonStyle(.borderedProminent)
                        Button("恢复真实定位", action: model.restore).buttonStyle(.bordered)
                    }.disabled(model.isBusy || settings.operationID != nil)
                    DisclosureGroup("无 Wi-Fi 辅助（实验）") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("适用于 LocalDevVPN 已开启、但使用蜂窝数据时无法连接设备的情况。将暂时关闭蜂窝数据，等待设备服务后执行定位，再尝试开启蜂窝数据。首次准备或手机重启后，请先连接 Wi-Fi 成功应用一次定位。")
                            Text("首次设置：在 iOS“快捷指令”App 中创建以下两条快捷指令。每条只需添加一个“设置蜂窝数据”动作；不要使用“切换”，不要添加“打开 App”动作。")
                            Text("① LocSign关闭蜂窝数据\n设置蜂窝数据 → 关闭\n\n② LocSign开启蜂窝数据\n设置蜂窝数据 → 打开")
                                .textSelection(.enabled)
                            Text("名称须完全一致。运行时允许快捷指令执行，完成后会自动返回 LocSign。此兼容路径尚需真机验证，不能保证恢复数据后连接继续保持。")
                            HStack {
                                Button("无 Wi-Fi 应用定位", action: model.applyWithoutWiFi)
                                Button("无 Wi-Fi 恢复定位", action: model.restoreWithoutWiFi)
                            }.buttonStyle(.bordered).disabled(model.isBusy || settings.operationID != nil)
                        }.font(.footnote).padding(.top, 8)
                    }
                    if let networkStatus = model.networkAssistStatus { Text(networkStatus).font(.subheadline) }
                    if model.requiresCellularRestore {
                        Text(model.cellularRestoreWarning ?? "蜂窝数据恢复待确认。如流程被中断，请先在“快捷指令”App 中停止仍在运行的指令，再运行恢复快捷指令，或在系统设置中开启蜂窝数据。")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("恢复蜂窝数据", action: model.restoreCellularData)
                            .disabled(model.isBusy || settings.operationID != nil)
                    }
                    if model.isBusy {
                        ProgressView()
                        Button("取消操作", role: .cancel, action: model.cancel)
                        if model.networkAssistStatus != nil {
                            Text("取消后仍会等待当前快捷指令返回，并尝试恢复蜂窝数据。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(model.status).font(.subheadline)
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Text("首次使用请开启 iOS 开发者模式并重启确认，保持设备解锁和 LocalDevVPN 开启。首次准备会联网向 Apple 申请开发者镜像个性化。系统可能在后台挂起定位连接；恢复按钮收到设备成功响应后才会显示已恢复。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("虚拟定位")
            .onChange(of: settings.host) { _, _ in Task { await model.settingsChanged() } }
            .onChange(of: settings.pairing) { _, _ in Task { await model.settingsChanged() } }
        }
    }
}
