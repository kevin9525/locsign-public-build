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
    private enum Tab: Hashable { case signing, location, settings }
    @StateObject private var services = ApplicationServices()
    @State private var selectedTab: Tab = .signing
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                SigningView(settings: services.installation, model: services.signing, account: services.account,
                    appsSection: AnyView(ManagedAppsSection(library: services.library, renewal: services.renewal,
                        settings: services.installation, account: services.account, ownRenewal: services.ownRenewal,
                        background: services.background)))
                    .tabItem { Label("签名", systemImage: "signature") }
                    .tag(Tab.signing)
                LocationView(model: services.location, settings: services.installation)
                    .tabItem { Label("定位", systemImage: "location.fill") }
                    .tag(Tab.location)
                SettingsView(settings: services.installation, account: services.account, signing: services.signing,
                    renewal: services.renewal, ownRenewal: services.ownRenewal, library: services.library,
                    background: services.background)
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .onChange(of: selectedTab, initial: true) { _, tab in
                // Manual renewals (and their certificate confirmations) run from the signing tab.
                services.renewal.manualConfirmationAvailable = tab == .signing && phase == .active
            }
            .task { await services.activate() }
            .onOpenURL { services.location.handleURL($0) }
            .onChange(of: phase) { _, value in
                services.renewal.manualConfirmationAvailable = selectedTab == .signing && value == .active
                if value == .active { Task { await services.activate() } }
                else if value == .background {
                    services.location.markBackground()
                    services.background.schedule()
                }
            }
        }
    }
}
