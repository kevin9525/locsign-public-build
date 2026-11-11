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
        background.register()
    }
    func activate() async {
        location.markForeground()
        guard !activating, installation.operationID == nil else { return }
        activating = true
        defer { activating = false }
        await account.restore()
        await background.foreground()
    }
}

@main
struct LocSignApp: App {
    @StateObject private var services = ApplicationServices()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView {
                SigningView(settings: services.installation, model: services.signing, account: services.account)
                    .tabItem { Label("安装", systemImage: "signature") }
                AppsView(library: services.library, renewal: services.renewal, settings: services.installation,
                    account: services.account, background: services.background)
                    .tabItem { Label("App", systemImage: "square.grid.2x2") }
                LocationView(model: services.location, settings: services.installation)
                    .tabItem { Label("定位", systemImage: "mappin.and.ellipse") }
                ConnectionView(settings: services.installation)
                    .tabItem { Label("连接", systemImage: "cable.connector") }
            }
            .task { await services.activate() }
            .onOpenURL { services.location.handleURL($0) }
            .onChange(of: phase) { _, value in
                if value == .active { Task { await services.activate() } }
                else if value == .background {
                    services.location.markBackground()
                    services.background.schedule()
                }
            }
        }
    }
}
