import Foundation
import XKit

final class ProvisioningBackendLive: ProvisioningBackend, @unchecked Sendable {
    private let configuration: AnisetteProviderConfiguration
    private let gateway: XKitAppleAccountGateway
    private let lock = NSLock()
    private var valid = true
    init(configuration: AnisetteProviderConfiguration, keychain: ProvisioningKeychain, account: String) throws {
        self.configuration = configuration
        self.gateway = try XKitAppleAccountGateway(configuration: configuration, keychain: keychain, account: account)
    }
    func invalidate() {
        lock.withLock { valid = false }
        gateway.storage?.invalidate()
    }
    private func check() throws {
        try Task.checkCancellation()
        guard lock.withLock({ valid }) else { throw CancellationError() }
    }
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession {
        try check()
        let result = try await AppleAccountClient(gateway: gateway, providerID: configuration.providerID)
            .logIn(appleID: appleID, password: password, twoFactorCode: twoFactorCode)
        try check()
        return result
    }
    func provision(request: ProvisioningRequest, session: AppleAccountSession, store: any ProvisioningMaterialStoring,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        try check()
        let app = try request.inspectedApp()
        guard session.providerID == configuration.providerID, session.account.id == request.accountID,
              session.account.teams.contains(where: { $0.id == request.teamID }), session.token.expiry > Date() else {
            throw ProvisioningError.invalidAccount
        }
        let service = XKitDeveloperServicesGateway(auth: .init(loginToken: session.token, teamID: .init(rawValue: request.teamID)),
            provider: gateway.provider, client: gateway.client)
        let provisioner = DeveloperServicesProvisioner(gateway: service, store: store, keys: ProvisioningKeyGenerator(),
            anchors: try ProvisioningProfileValidator.apple().trustAnchors, now: { Date() })
        try check()
        let material = try await provisioner.provision(app: app, deviceUDID: request.deviceUDID, teamID: request.teamID,
            confirmRevocation: confirmRevocation)
        try check()
        return material
    }
}

extension ProvisioningEngineLive {
    static func live(configuration: AnisetteProviderConfiguration) throws -> ProvisioningEngineLive {
        let keychain = ProvisioningKeychain()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try ProvisioningEngineLive(configuration: configuration, keychain: keychain,
            markerURL: directory.appendingPathComponent("Provisioning/installation-v1"),
            makeBackend: { account in try ProvisioningBackendLive(configuration: configuration, keychain: keychain, account: account) })
    }
}
