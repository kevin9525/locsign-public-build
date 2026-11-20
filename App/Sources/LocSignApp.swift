import SwiftUI

@MainActor
final class ApplicationServices: ObservableObject {
    let installation: InstallationSettings
    let account: AppleIDProvisioningModel
    let signing: SigningViewModel
    let library: ManagedAppLibrary
    let renewal: AppRenewalCoordinator
    let background: RenewalBackgroundService
    let location: LocationViewModel
    let ownRenewal: SelfRenewalModel
    private var activating = false

    init() {
        let settings = InstallationSettings.live()
        let library = ManagedAppLibrary.live()
        let account = AppleIDProvisioningModel(settings: settings)
        let renewal = AppRenewalCoordinator(settings: settings, library: library, account: account)
        installation = settings; self.library = library; self.account = account; self.renewal = renewal
        signing = SigningViewModel(settings: settings, library: library)
        background = RenewalBackgroundService(renewal: renewal, library: library, settings: settings)
        location = LocationViewModel(settings: settings)
        ownRenewal = SelfRenewalModel(defaults: settings.defaults)
        background.register()
    }
    func activate() async {
        location.markForeground()
        guard !activating, installation.operationID == nil else { return }
        activating = true
        defer { activating = false }
        await ownRenewal.refresh()
        await account.restore()
        await background.foreground()
    }
}

@main
struct LocSignApp: App {
    private enum Tab: Hashable { case installation, apps, location, connection }
    @StateObject private var services = ApplicationServices()
    @State private var selectedTab: Tab = .installation
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                SigningView(settings: services.installation, model: services.signing, account: services.account)
                    .tabItem { Label("安装", systemImage: "signature") }
                    .tag(Tab.installation)
                AppsView(library: services.library, renewal: services.renewal, settings: services.installation,
                    account: services.account, ownRenewal: services.ownRenewal, background: services.background)
                    .tabItem { Label("App", systemImage: "square.grid.2x2") }
                    .tag(Tab.apps)
                LocationView(model: services.location, settings: services.installation)
                    .tabItem { Label("定位", systemImage: "mappin.and.ellipse") }
                    .tag(Tab.location)
                ConnectionView(settings: services.installation)
                    .tabItem { Label("连接", systemImage: "cable.connector") }
                    .tag(Tab.connection)
            }
            .onChange(of: selectedTab, initial: true) { _, tab in
                services.renewal.manualConfirmationAvailable = tab == .apps && phase == .active
            }
            .task { await services.activate() }
            .onOpenURL { services.location.handleURL($0) }
            .onChange(of: phase) { _, value in
                services.renewal.manualConfirmationAvailable = selectedTab == .apps && value == .active
                if value == .active { Task { await services.activate() } }
                else if value == .background {
                    services.location.markBackground()
                    services.background.schedule()
                }
            }
        }
    }
}
