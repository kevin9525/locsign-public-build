import Foundation
import Combine
import MapKit

enum LocationConnectionMode: String, CaseIterable, Identifiable {
    case direct, assisted

    var id: String { rawValue }
    var title: String { self == .direct ? "直接连接" : "无 Wi-Fi 辅助" }
}

@MainActor
final class LocationViewModel: ObservableObject {
    @Published var latitude = "" { didSet { dropPlaceNameIfEdited() } }
    @Published var longitude = "" { didSet { dropPlaceNameIfEdited() } }
    @Published var searchText = ""
    @Published private(set) var inputSystem: LocationCoordinateSystem = .wgs84
    @Published private(set) var mapRegion: LocationMapRegion = .mainlandChina
    @Published private(set) var searchResults: [MKMapItem] = []
    @Published private(set) var selected: CLLocationCoordinate2D?
    @Published private(set) var isBusy = false
    @Published private(set) var isSearching = false
    @Published private(set) var status = "尚未应用模拟定位"
    @Published private(set) var error: String?
    @Published private(set) var networkAssistStatus: String?
    @Published private(set) var requiresCellularRestore = false
    @Published private(set) var cellularRestoreWarning: String?
    @Published private(set) var connectionMode: LocationConnectionMode
    @Published private(set) var restorationNotice: String?
    /// Name of the place the fields came from; cleared when the fields are edited.
    @Published private(set) var selectedPlaceName: String?
    /// Problems saving favorites/history. Never replaces a device result.
    @Published private(set) var placesMessage: String?
    let places: LocationPlacesStore
    private var namedFields: (latitude: String, longitude: String)?
    private let settings: InstallationSettings
    private let controller: any DeviceLocationControlling
    private let networkAssist: LocationNetworkAssist
    private let shortcutRunner: LocationShortcutRunner
    private var sessionFailure: String?
    private var search: MKLocalSearch?
    private var searchID = UUID()
    private var operation: Task<Void, Never>?
    private var backgrounded = false

    init(settings: InstallationSettings, controller: (any DeviceLocationControlling)? = nil,
         networkAssist: LocationNetworkAssist? = nil) {
        let controller = controller ?? DeviceLocationController()
        self.settings = settings; self.controller = controller
        places = LocationPlacesStore(defaults: settings.defaults)
        connectionMode = settings.defaults.string(forKey: "location.connectionMode")
            .flatMap(LocationConnectionMode.init(rawValue:)) ?? .direct
        let runner = LocationShortcutRunner()
        shortcutRunner = runner
        self.networkAssist = networkAssist ?? LocationNetworkAssist(defaults: settings.defaults,
            runShortcut: { try await runner.run($0) },
            probe: { host, timeout in try await controller.prepareConnection(host: host, timeout: timeout) })
        self.networkAssist.onChange = { [weak self] in self?.updateNetworkAssistState() }
        updateNetworkAssistState()
        inputSystem = settings.defaults.string(forKey: "location.coordinateSystem")
            .flatMap(LocationCoordinateSystem.init(rawValue:)) ?? .wgs84
        mapRegion = settings.defaults.string(forKey: "location.mapRegion")
            .flatMap(LocationMapRegion.init(rawValue:)) ?? .mainlandChina
        controller.onSessionFailure = { [weak self] message in
            Task { @MainActor in
                self?.status = "定位连接中断，当前设备状态未确认"
                self?.error = ProvisioningRedaction.redact(message)
                self?.sessionFailure = ProvisioningRedaction.redact(message)
                self?.restorationNotice = nil
            }
        }
        if let lat = settings.defaults.object(forKey: "location.latitude") as? Double,
           let lon = settings.defaults.object(forKey: "location.longitude") as? Double,
           let point = try? LocationCoordinate(latitude: lat, longitude: lon) {
            storeSelection(point)
        }
        placesMessage = places.loadError
    }
    func selectMapCoordinate(_ point: CLLocationCoordinate2D) {
        guard !isBusy, let coordinate = try? LocationCoordinate(latitude: point.latitude, longitude: point.longitude) else { return }
        inputSystem = mapRegion.coordinateSystem
        storeSelection(coordinate)
    }
    func selectSearchCoordinate(_ point: CLLocationCoordinate2D, countryCode: String?, name: String? = nil) {
        guard !isBusy, let coordinate = try? LocationCoordinate(latitude: point.latitude, longitude: point.longitude) else { return }
        if let country = countryCode?.uppercased(), !country.isEmpty {
            mapRegion = country == "CN" ? .mainlandChina : .otherRegions
        }
        inputSystem = mapRegion.coordinateSystem
        storeSelection(coordinate)
        setPlaceName(name)
    }
    /// Fills the fields from a saved place. Nothing is sent to the device until Apply.
    func selectPlace(_ place: SavedLocationPlace) {
        guard !isBusy, let coordinate = place.coordinate else { return }
        mapRegion = place.mapRegion
        inputSystem = place.coordinateSystem
        storeSelection(coordinate)
        setPlaceName(place.name)
        placesMessage = places.loadError
    }
    func saveFavorite(name: String) throws {
        guard !isBusy, settings.operationID == nil else { throw LocationPlacesError.busy }
        let coordinate = try enteredCoordinate()
        try places.saveFavorite(name: name, coordinate: coordinate, system: inputSystem, region: mapRegion)
        setPlaceName(try LocationPlacesStore.normalizedName(name))
        placesMessage = nil
    }
    func renameFavorite(_ place: SavedLocationPlace, to name: String) {
        guard !isBusy else { return }
        updatePlaces { try places.renameFavorite(id: place.id, name: name) }
    }
    func deleteFavorite(_ place: SavedLocationPlace) {
        guard !isBusy else { return }
        updatePlaces { try places.deleteFavorite(id: place.id) }
    }
    func deleteRecent(_ place: SavedLocationPlace) {
        guard !isBusy else { return }
        updatePlaces { try places.deleteRecent(id: place.id) }
    }
    func clearRecents() {
        guard !isBusy else { return }
        updatePlaces { try places.clearRecents() }
    }
    private func updatePlaces(_ change: () throws -> Void) {
        do { try change(); placesMessage = nil }
        catch { placesMessage = error.localizedDescription }
    }
    private func setPlaceName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedPlaceName = trimmed?.isEmpty == false ? trimmed : nil
        namedFields = selectedPlaceName == nil ? nil : (latitude, longitude)
    }
    private func dropPlaceNameIfEdited() {
        guard let namedFields, namedFields.latitude != latitude || namedFields.longitude != longitude else { return }
        self.namedFields = nil
        selectedPlaceName = nil
    }
    func setInputSystem(_ system: LocationCoordinateSystem) {
        guard !isBusy else { return }
        if system != inputSystem { setPlaceName(nil) }
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
    func setConnectionMode(_ mode: LocationConnectionMode) {
        guard !isBusy, settings.operationID == nil, !networkAssist.requiresRestore else { return }
        connectionMode = mode
        settings.defaults.set(mode.rawValue, forKey: "location.connectionMode")
    }
    func apply() { start(clear: false, useNetworkAssist: connectionMode == .assisted) }
    func restore() { start(clear: true, useNetworkAssist: connectionMode == .assisted) }
    func handleURL(_ url: URL) { shortcutRunner.handle(url) }
    private func updateNetworkAssistState() {
        networkAssistStatus = networkAssist.status
        requiresCellularRestore = networkAssist.requiresRestore
        cellularRestoreWarning = networkAssist.restoreWarning
    }
    func restoreCellularData() {
        guard !isBusy, requiresCellularRestore, let token = settings.beginOperation() else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil; settings.endOperation(token) }
            await networkAssist.restoreData()
        }
    }
    func cancel() { operation?.cancel(); if isBusy { status = "正在取消，等待当前设备请求结束…" } }
    func markForeground() { backgrounded = false }
    func markBackground() {
        backgrounded = true
        if status.contains("设备已接受模拟坐标") { status = "应用进入后台，定位连接持续性未确认；回到前台后可重新应用或恢复" }
    }
    func settingsChanged() async {
        operation?.cancel()
        await controller.disconnect()
        restorationNotice = nil
        status = "设备设置已变化，请重新应用或恢复定位"
    }
    private func enteredCoordinate() throws -> LocationCoordinate {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LocSignError.install("请输入有效的纬度和经度，可使用负号表示南纬或西经")
        }
        return try LocationCoordinate(latitude: lat, longitude: lon)
    }
    private func start(clear: Bool, useNetworkAssist: Bool = false) {
        guard !isBusy, settings.operationID == nil else { return }
        guard let pairing = settings.pairing?.data else { error = "请先在安装页导入这台手机的配对文件"; return }
        let coordinate: LocationCoordinate?
        let input: LocationCoordinate?
        let system = inputSystem
        let region = mapRegion
        let placeName = selectedPlaceName
        do {
            input = try (clear ? nil : enteredCoordinate())
            coordinate = try input.map { try LocationCoordinateConversion.convert($0, from: system, to: .wgs84) }
        }
        catch { self.error = error.localizedDescription; return }
        guard let token = settings.beginOperation() else { return }
        isBusy = true; error = nil; sessionFailure = nil; restorationNotice = nil
        status = clear ? "正在连接并恢复真实定位…" : "正在准备开发者服务并应用定位…"
        let host = settings.host
        operation = Task {
            defer { isBusy = false; operation = nil; settings.endOperation(token) }
            do {
                let perform: () async throws -> Void = { [self] in
                    if clear { try await controller.clear(host: host, pairingData: pairing) }
                    else if let coordinate { try await controller.set(coordinate, host: host, pairingData: pairing) }
                }
                if useNetworkAssist {
                    // Do not reuse a session from the network before the shortcut.
                    await controller.disconnect()
                    try await networkAssist.run(host: host, operation: perform)
                } else { try await perform() }
                try Task.checkCancellation()
                status = clear ? "设备已接受恢复真实定位" : backgrounded ? "应用进入后台，定位连接持续性未确认；回到前台后可重新应用或恢复" : "设备已接受模拟坐标，保持当前页面可维持连接"
                if useNetworkAssist && !clear { status = "设备已接受本次模拟坐标；蜂窝数据切换后请在地图中核对，持续定位尚待确认" }
                if let sessionFailure { status = "定位连接中断，当前设备状态未确认"; error = sessionFailure }
                else if clear {
                    restorationNotice = "已停止发送模拟位置。其他 App 可能暂时显示旧地址，可点“重新定位”或重新打开 App；保存的城市和收货地址需手动切换。请以地图定位箭头获取的蓝点核对当前位置。"
                }
                if !clear, let input {
                    inputSystem = system
                    storeSelection(input)
                    setPlaceName(placeName)
                    // Only a confirmed, uninterrupted apply becomes history. A
                    // history failure never turns the device result into an error.
                    if sessionFailure == nil {
                        let name = placeName ?? String(format: "%.6f, %.6f", input.latitude, input.longitude)
                        do {
                            try places.recordRecent(name: name, coordinate: input, system: system, region: region)
                            placesMessage = nil
                        } catch { placesMessage = "定位已应用，但未能记入最近使用：" + error.localizedDescription }
                    }
                }
            } catch {
                await controller.disconnect()
                status = "操作未完成，设备定位状态未确认"
                self.error = error is CancellationError ? "操作已取消，可重新连接后恢复真实定位" : ProvisioningRedaction.redact(error.localizedDescription)
            }
        }
    }
}
