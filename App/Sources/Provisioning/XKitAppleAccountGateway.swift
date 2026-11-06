import Foundation
import XKit
import XUtils
import Dependencies

struct XKitAppleAccountGateway: AppleAccountGateway {
    let provider: any AnisetteDataProvider
    let client: any HTTPClientProtocol
    let storage: AnisetteKeychainStorage?

    init(provider: any AnisetteDataProvider, client: any HTTPClientProtocol) {
        self.provider = provider; self.client = client; self.storage = nil
    }
    init(configuration: AnisetteProviderConfiguration, keychain: ProvisioningKeychain, account: String) throws {
        let storage = AnisetteKeychainStorage(keychain: keychain, account: account, provider: configuration.providerID)
        let appleClient = XKitHTTPClientAdapter(boundary: .apple)
        let raw = LocSignRawADIProvider(configuration: configuration, client: XKitHTTPClientAdapter(boundary: .provider(configuration)))
        self.provider = try withDependencies {
            $0.keyValueStorage = storage
            $0.httpClient = appleClient
            $0.rawADIProvider = raw
        } operation: { try ADIDataProvider(providerID: configuration.providerID) }
        self.client = appleClient
        self.storage = storage
    }

    func authenticate(appleID: String, password: String, twoFactor: @escaping TwoFactorCodeProvider) async throws -> DeveloperServicesLoginToken {
        let delegate = AppleTwoFactorDelegate(callback: twoFactor)
        do {
            try Task.checkCancellation()
            return try await withDependencies {
                $0.httpClient = client
                $0.anisetteDataProvider = provider
                $0.out = CommandOutput { _, _, _ in }
            } operation: {
                try await DeveloperServicesLoginManager().logIn(withUsername: appleID, password: password, twoFactorDelegate: delegate)
            }
        } catch { throw Self.safeError(error) }
    }
    func teams(token: DeveloperServicesLoginToken) async throws -> [DeveloperServicesTeam] {
        do {
            try Task.checkCancellation()
            return try await withDependencies {
                $0.httpClient = client
                $0.anisetteDataProvider = provider
                $0.out = CommandOutput { _, _, _ in }
            } operation: { try await DeveloperServicesClient(loginToken: token).send(DeveloperServicesListTeamsRequest()) }
        } catch { throw Self.safeError(error) }
    }

    private static func safeError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        switch DeveloperServicesLoginManager.authenticationFailure(for: error) {
        case .invalidCredentials: return AppleAccountError.invalidCredentials
        case .invalidVerificationCode, .failedSecondaryAuth: return AppleAccountError.invalidCode
        case .cancelled: return AppleAccountError.cancelled
        case .invalidAnisette: return AppleAccountError.unavailable
        case .service(let code): return AppleAccountError.rejected(code)
        case nil: break
        }
        if error is URLError || error is ProvisioningNetworkError { return AppleAccountError.network }
        return AppleAccountError.rejected(nil)
    }
}

actor AppleTwoFactorDelegate: TwoFactorAuthDelegate {
    private var callback: TwoFactorCodeProvider?
    init(callback: @escaping TwoFactorCodeProvider) { self.callback = callback }
    func fetchCode() async -> String? {
        guard !Task.isCancelled, let callback else { self.callback = nil; return nil }
        self.callback = nil
        guard let raw = await callback(), !Task.isCancelled else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }
}
