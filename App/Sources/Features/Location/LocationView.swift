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
                    MapReader { proxy in
                        Map(position: $position) {
                            if let selected = model.selected {
                                Marker("所选坐标", coordinate: selected)
                            }
                        }
                        .mapControls { MapCompass(); MapScaleView() }
                        .onTapGesture { point in
                            if let coordinate = proxy.convert(point, from: .local) { model.select(coordinate) }
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
                            model.select(point)
                            position = .region(.init(center: point, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "地点")
                                Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    HStack {
                        TextField("纬度 −90…90", text: $model.latitude).textFieldStyle(.roundedBorder)
                        TextField("经度 −180…180", text: $model.longitude).textFieldStyle(.roundedBorder)
                    }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("在地图上显示坐标") {
                        model.selectManual()
                        if let point = model.selected { position = .region(.init(center: point, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))) }
                    }
                    HStack {
                        Button("应用定位", action: model.apply).buttonStyle(.borderedProminent)
                        Button("恢复真实定位", action: model.restore).buttonStyle(.bordered)
                    }.disabled(model.isBusy || settings.operationID != nil)
                    if model.isBusy {
                        ProgressView()
                        Button("取消操作", role: .cancel, action: model.cancel)
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
