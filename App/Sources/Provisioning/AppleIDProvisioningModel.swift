import Foundation
import Combine

@MainActor
final class AppleIDProvisioningModel: ObservableObject {
    typealias EngineFactory = @MainActor (AnisetteProviderConfiguration) throws -> any ProvisioningEngine
    @Published var endpoint = "https://mac-ani.jkcoxson.com"
    @Published var providerEnabled = true
    @Published var providerAccepted = false
    @Published var appleID = ""
    @Published var password = ""
    @Published var code = ""
    @Published var teamID = ""
    @Published private(set) var account: ProvisioningAccount?
    @Published private(set) var isBusy = false
    @Published private(set) var awaitingCode = false
    @Published private(set) var revocations: [CertificateRevocation] = []
    @Published private(set) var error: String?
    private let factory: EngineFactory
    init(factory: @escaping EngineFactory = { _ in throw ProvisioningError.providerUnavailable("尚未接入") }) { self.factory = factory }
    var engine: (any ProvisioningEngine)? { nil }
    func restore() async {}
    func logIn() async { error = "登录尚未接入" }
    func submitCode() {}
    func cancel() async { password = ""; code = "" }
    func logout() async {}
    func confirmRevocation(_ candidates: [CertificateRevocation]) async -> Bool { false }
    func resolveRevocation(_ confirmed: Bool) {}
    func changeProvider() async {}
}
