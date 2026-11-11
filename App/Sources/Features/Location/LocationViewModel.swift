import Foundation
import Combine
import MapKit

@MainActor
final class LocationViewModel: ObservableObject {
    @Published var latitude = ""
    @Published var longitude = ""
    @Published var searchText = ""
    @Published private(set) var inputSystem: LocationCoordinateSystem = .wgs84
    @Published private(set) var mapRegion: LocationMapRegion = .mainlandChina
    @Published private(set) var searchResults: [MKMapItem] = []
    @Published private(set) var selected: CLLocationCoordinate2D?
    @Published private(set) var isBusy = false
    @Published private(set) var isSearching = false
    @Published private(set) var status = "尚未应用模拟定位"
    @Published private(set) var error: String?
    private let settings: InstallationSettings
    private let controller: any DeviceLocationControlling
    private var search: MKLocalSearch?
    private var searchID = UUID()
    private var operation: Task<Void, Never>?
    private var backgrounded = false

    init(settings: InstallationSettings, controller: (any DeviceLocationControlling)? = nil) {
        let controller = controller ?? DeviceLocationController()
        self.settings = settings; self.controller = controller
        inputSystem = settings.defaults.string(forKey: "location.coordinateSystem")
            .flatMap(LocationCoordinateSystem.init(rawValue:)) ?? .wgs84
        mapRegion = settings.defaults.string(forKey: "location.mapRegion")
            .flatMap(LocationMapRegion.init(rawValue:)) ?? .mainlandChina
        controller.onSessionFailure = { [weak self] message in
            Task { @MainActor in
                self?.status = "定位连接中断，当前设备状态未确认"
                self?.error = ProvisioningRedaction.redact(message)
            }
        }
        if let lat = settings.defaults.object(forKey: "location.latitude") as? Double,
           let lon = settings.defaults.object(forKey: "location.longitude") as? Double,
           let point = try? LocationCoordinate(latitude: lat, longitude: lon) {
            storeSelection(point)
        }
    }
    func selectMapCoordinate(_ point: CLLocationCoordinate2D) {
        guard !isBusy, let coordinate = try? LocationCoordinate(latitude: point.latitude, longitude: point.longitude) else { return }
        inputSystem = mapRegion.coordinateSystem
        storeSelection(coordinate)
    }
    func selectSearchCoordinate(_ point: CLLocationCoordinate2D, countryCode: String?) {
        guard !isBusy, let coordinate = try? LocationCoordinate(latitude: point.latitude, longitude: point.longitude) else { return }
        if let country = countryCode?.uppercased(), !country.isEmpty {
            mapRegion = country == "CN" ? .mainlandChina : .otherRegions
        }
        inputSystem = mapRegion.coordinateSystem
        storeSelection(coordinate)
    }
    func setInputSystem(_ system: LocationCoordinateSystem) {
        guard !isBusy else { return }
        inputSystem = system
        selected = nil // The new interpretation is previewed explicitly or after apply.
    }
    func setMapRegion(_ region: LocationMapRegion) {
        guard !isBusy else { return }
        mapRegion = region
        settings.defaults.set(region.rawValue, forKey: "location.mapRegion")
        if let input = try? enteredCoordinate() { selected = try? displayedCoordinate(input, system: inputSystem) }
    }
    private func displayedCoordinate(_ input: LocationCoordinate, system: LocationCoordinateSystem) throws -> CLLocationCoordinate2D {
        let point = try LocationCoordinateConversion.convert(input, from: system, to: mapRegion.coordinateSystem)
        return .init(latitude: point.latitude, longitude: point.longitude)
    }
    private func storeSelection(_ point: LocationCoordinate) {
        selected = try? displayedCoordinate(point, system: inputSystem)
        latitude = String(format: "%.6f", point.latitude)
        longitude = String(format: "%.6f", point.longitude)
        settings.defaults.set(point.latitude, forKey: "location.latitude")
        settings.defaults.set(point.longitude, forKey: "location.longitude")
        settings.defaults.set(inputSystem.rawValue, forKey: "location.coordinateSystem")
        settings.defaults.set(mapRegion.rawValue, forKey: "location.mapRegion")
    }
    func selectManual() {
        guard !isBusy else { return }
        do { let coordinate = try enteredCoordinate(); _ = try displayedCoordinate(coordinate, system: inputSystem); storeSelection(coordinate); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func searchAddress() async {
        search?.cancel()
        let id = UUID(); searchID = id
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = []; isSearching = false; search = nil; return }
        isSearching = true
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        let current = MKLocalSearch(request: request); search = current
        defer { if searchID == id { isSearching = false; search = nil } }
        do {
            let response = try await current.start()
            guard searchID == id else { return }
            searchResults = Array(response.mapItems.prefix(15)); error = nil
        } catch { if searchID == id { self.error = "地址搜索失败：" + error.localizedDescription } }
    }
    func apply() { start(clear: false) }
    func restore() { start(clear: true) }
    func cancel() { operation?.cancel(); if isBusy { status = "正在取消，等待当前设备请求结束…" } }
    func markForeground() { backgrounded = false }
    func markBackground() {
        backgrounded = true
        if status.contains("设备已接受模拟坐标") { status = "应用进入后台，定位连接持续性未确认；回到前台后可重新应用或恢复" }
    }
    func settingsChanged() async {
        operation?.cancel()
        await controller.disconnect()
        status = "设备设置已变化，请重新应用或恢复定位"
    }
    private func enteredCoordinate() throws -> LocationCoordinate {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LocSignError.install("请输入有效的纬度和经度，可使用负号表示南纬或西经")
        }
        return try LocationCoordinate(latitude: lat, longitude: lon)
    }
    private func start(clear: Bool) {
        guard !isBusy, settings.operationID == nil else { return }
        guard let pairing = settings.pairing?.data else { error = "请先在安装页导入这台手机的配对文件"; return }
        let coordinate: LocationCoordinate?
        let input: LocationCoordinate?
        let system = inputSystem
        do {
            input = try (clear ? nil : enteredCoordinate())
            coordinate = try input.map { try LocationCoordinateConversion.convert($0, from: system, to: .wgs84) }
        }
        catch { self.error = error.localizedDescription; return }
        guard let token = settings.beginOperation() else { return }
        isBusy = true; error = nil
        status = clear ? "正在连接并恢复真实定位…" : "正在准备开发者服务并应用定位…"
        let host = settings.host
        operation = Task {
            defer { isBusy = false; operation = nil; settings.endOperation(token) }
            do {
                if clear { try await controller.clear(host: host, pairingData: pairing) }
                else if let coordinate { try await controller.set(coordinate, host: host, pairingData: pairing) }
                try Task.checkCancellation()
                status = clear ? "设备已接受恢复真实定位" : backgrounded ? "应用进入后台，定位连接持续性未确认；回到前台后可重新应用或恢复" : "设备已接受模拟坐标，保持当前页面可维持连接"
                if !clear, let input {
                    inputSystem = system
                    storeSelection(input)
                }
            } catch {
                status = "操作未完成，设备定位状态未确认"
                self.error = error is CancellationError ? "操作已取消，可重新连接后恢复真实定位" : ProvisioningRedaction.redact(error.localizedDescription)
            }
        }
    }
}
