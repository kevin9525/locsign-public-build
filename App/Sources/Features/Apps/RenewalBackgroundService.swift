import BackgroundTasks
import UIKit
import UserNotifications

@MainActor
final class RenewalBackgroundService {
    static let identifier = "com.locsign.renew-apps"
    private let renewal: AppRenewalCoordinator
    private let library: ManagedAppLibrary
    private let settings: InstallationSettings
    private var registered = false

    init(renewal: AppRenewalCoordinator, library: ManagedAppLibrary, settings: InstallationSettings) {
        self.renewal = renewal; self.library = library; self.settings = settings
        renewal.notifyFailure = { name in
            let content = UNMutableNotificationContent()
            content.title = "LocSign 续签需要处理"
            content.body = "\(name) 暂未续签成功，请打开 LocSign 查看原因。"
            content.sound = .default
            let id = "renewal.failure." + name
            try? await UNUserNotificationCenter.current().add(.init(identifier: id, content: content, trigger: nil))
        }
    }

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] background in
            Task { @MainActor in
                guard let self else { background.setTaskCompleted(success: false); return }
                let task = Task { @MainActor in
                    guard UIApplication.shared.isProtectedDataAvailable, self.settings.operationID == nil else {
                        self.schedule(); background.setTaskCompleted(success: false); return
                    }
                    self.reloadProtectedState()
                    // Preserve a future opportunity even if iOS terminates this
                    // process while cancellation drains a native signer.
                    self.schedule()
                    let success = await self.renewal.runDue()
                    self.schedule()
                    background.setTaskCompleted(success: success)
                }
                background.expirationHandler = { task.cancel() }
            }
        }
    }

    func foreground() async {
        guard UIApplication.shared.isProtectedDataAvailable, settings.operationID == nil else { return }
        reloadProtectedState()
        _ = await renewal.runDue()
        schedule()
    }

    private func reloadProtectedState() {
        library.reload()
        settings.reloadPairing()
        if let bundle = Bundle.main.bundleIdentifier,
           let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            try? library.reconcileSelf(bundleID: bundle, embeddedProfile: data)
        }
        try? library.recoverInterrupted(runningBundleID: Bundle.main.bundleIdentifier)
    }

    func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    func requestNotificationsIfNeeded() async {
        guard renewal.enabled else { return }
        let authorization = await UNUserNotificationCenter.current().notificationSettings()
        if authorization.authorizationStatus == .notDetermined { _ = await requestNotifications() }
    }
    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        guard renewal.enabled else { return }
        let next = library.apps.compactMap { AppRenewalPolicy.nextDate($0, now: Date(), runningBundleID: Bundle.main.bundleIdentifier) }.min()
        // Locked startup may make the protected manifest unavailable; retry
        // later rather than permanently losing the OS scheduling opportunity.
        guard next != nil || library.loadError != nil else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = next ?? Date().addingTimeInterval(AppRenewalPolicy.retryInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
