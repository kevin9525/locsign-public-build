import Foundation

protocol ProvisioningEngine: Sendable {
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount
    func restoreAccount() async throws -> ProvisioningAccount?
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial
    func cancel() async
    func logout(account: String) async throws
}

protocol ProvisioningBackend: Sendable {
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> AppleAccountSession
    func provision(request: ProvisioningRequest, session: AppleAccountSession, store: any ProvisioningMaterialStoring,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial
    func invalidate()
}

actor ProvisioningEngineLive: ProvisioningEngine {
    typealias BackendFactory = @Sendable (String) throws -> any ProvisioningBackend
    private let configuration: AnisetteProviderConfiguration
    private let keychain: ProvisioningKeychain
    private let makeBackend: BackendFactory
    private let trustAnchors: [Data]?
    private var session: AppleAccountSession?
    private var backend: (any ProvisioningBackend)?
    private var generation = UUID()
    private static let materialNamespace = "signing-material-v1"

    init(configuration: AnisetteProviderConfiguration, keychain: ProvisioningKeychain, markerURL: URL,
         trustAnchors: [Data]? = nil, makeBackend: @escaping BackendFactory) throws {
        try keychain.prepareInstallation(markerURL: markerURL)
        self.configuration = configuration
        self.keychain = keychain
        self.trustAnchors = trustAnchors
        self.makeBackend = makeBackend
    }

    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount {
        let account = ProvisioningKeychain.normalize(appleID)
        guard !account.isEmpty, !password.isEmpty else { throw AppleAccountError.invalidCredentials }
        let operation = begin()
        let context = try makeBackend(account)
        backend = context
        let result: AppleAccountSession
        do {
            result = try await context.logIn(appleID: account, password: password, twoFactorCode: {
                guard await self.isCurrent(operation) else { return nil }
                let code = await twoFactorCode()
                return await self.isCurrent(operation) ? code : nil
            })
            try check(operation)
            guard result.account.appleID == account, result.providerID == configuration.providerID,
                  result.token.expiry > Date(), !result.token.adsid.isEmpty, !result.token.token.isEmpty,
                  !result.account.teams.isEmpty else { throw ProvisioningError.invalidAccount }
            // One atomic Keychain item contains the token and opaque account handle.
            try keychain.write(JSONEncoder().encode(result), account: "", provider: "engine", team: "", key: "session")
            session = result
            return result.account
        } catch {
            context.invalidate()
            if generation == operation { backend = nil }
            throw error
        }
    }

    func restoreAccount() async throws -> ProvisioningAccount? {
        try Task.checkCancellation()
        guard let data = try keychain.read(account: "", provider: "engine", team: "", key: "session") else {
            session = nil
            return nil
        }
        let saved = try JSONDecoder().decode(AppleAccountSession.self, from: data)
        guard saved.providerID == configuration.providerID, saved.token.expiry > Date(),
              !saved.token.token.isEmpty, !saved.token.adsid.isEmpty, !saved.account.teams.isEmpty else {
            backend?.invalidate()
            backend = nil
            session = nil
            try keychain.remove(account: "", provider: "engine", team: "", key: "session")
            // Provider changes invalidate authentication/ADI, while signing
            // identities use their own stable namespace and remain intact.
            for key in ["XTLLocalUserUID", "XTLADIProviderID", "XTLProvisioningInfo", "XTLRoutingInfo"] {
                try keychain.remove(account: saved.account.appleID, provider: saved.providerID,
                                    team: "", key: "anisette." + key)
            }
            return nil
        }
        session = saved
        return saved.account
    }

    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        guard let session, session.account.id == request.accountID,
              session.account.teams.contains(where: { $0.id == request.teamID }),
              session.providerID == configuration.providerID, session.token.expiry > Date(),
              !request.deviceUDID.isEmpty else { throw ProvisioningError.invalidAccount }
        let operation = begin()
        let context = try makeBackend(session.account.appleID)
        backend = context
        let store = GuardedProvisioningStore(engine: self, operation: operation,
                                             account: session.account.appleID, team: request.teamID)
        do {
            let material = try await context.provision(request: request, session: session, store: store,
                confirmRevocation: { candidates in
                    guard await self.isCurrent(operation) else { return false }
                    let confirmed = await confirmRevocation(candidates)
                    return await self.isCurrent(operation) && confirmed
                })
            try check(operation)
            guard let pending = try loadPending(operation: operation, account: session.account.appleID, team: request.teamID),
                  let certificate = pending.certificate, let der = certificate.der,
                  Data(material.privateKeyPEM.utf8) == pending.privateKeyPEM else { throw ProfileValidationError.certificate }
            let validator: ProvisioningProfileValidator
            if let trustAnchors { validator = ProvisioningProfileValidator(trustAnchors: trustAnchors) }
            else { validator = try .apple() }
            let app = try ProvisioningIPAPreflight().inspect(request.ipaURL)
            // Independently enforce the backend's authenticated-material contract
            // before replacing active material; no plist dictionary is actor state.
            let verified = try validator.validate(data: material.profileData,
                expectedBundleID: app.bundleID,
                expectedTeamID: request.teamID, expectedUDID: request.deviceUDID,
                expectedCertificateDER: der, privateKeyPEM: pending.privateKeyPEM)
            let active = ActiveSigningMaterial(certificateID: certificate.id, bundleID: verified.profile.bundleID,
                                              deviceUDID: request.deviceUDID, material: material)
            try check(operation)
            try keychain.write(JSONEncoder().encode(active), account: session.account.appleID,
                               provider: Self.materialNamespace, team: request.teamID, key: "active")
            return material
        } catch {
            if generation == operation {
                context.invalidate()
                backend = nil
            }
            throw error
        }
    }

    func cancel() async { _ = begin() }

    func logout(account: String) async throws {
        _ = begin()
        let normalized = ProvisioningKeychain.normalize(account)
        if session?.account.appleID == normalized { session = nil }
        if let data = try keychain.read(account: "", provider: "engine", team: "", key: "session"),
           try JSONDecoder().decode(AppleAccountSession.self, from: data).account.appleID == normalized {
            try keychain.remove(account: "", provider: "engine", team: "", key: "session")
        }
        try keychain.removeAll(account: normalized)
    }

    private func begin() -> UUID {
        generation = UUID()
        backend?.invalidate()
        backend = nil
        return generation
    }
    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard generation == operation else { throw ProvisioningError.cancelled }
    }
    private func isCurrent(_ operation: UUID) -> Bool { generation == operation && !Task.isCancelled }

    fileprivate func loadPending(operation: UUID, account: String, team: String) throws -> PendingSigningMaterial? {
        try check(operation)
        return try keychain.read(account: account, provider: Self.materialNamespace, team: team, key: "pending")
            .map { try JSONDecoder().decode(PendingSigningMaterial.self, from: $0) }
    }
    fileprivate func savePending(_ material: PendingSigningMaterial, operation: UUID, account: String, team: String) throws {
        try check(operation)
        try keychain.write(JSONEncoder().encode(material), account: account, provider: Self.materialNamespace, team: team, key: "pending")
    }
    fileprivate func invalidateCertificate(_ id: String, operation: UUID, account: String, team: String) throws {
        try check(operation)
        if var pending = try loadPending(operation: operation, account: account, team: team), pending.certificate?.id == id {
            pending.certificate = nil
            try savePending(pending, operation: operation, account: account, team: team)
        }
        if let data = try keychain.read(account: account, provider: Self.materialNamespace, team: team, key: "active"),
           try JSONDecoder().decode(ActiveSigningMaterial.self, from: data).certificateID == id {
            try keychain.remove(account: account, provider: Self.materialNamespace, team: team, key: "active")
        }
    }
}

private struct ActiveSigningMaterial: Codable {
    let certificateID: String
    let bundleID: String
    let deviceUDID: String
    let material: ProvisioningMaterial
}
private struct GuardedProvisioningStore: ProvisioningMaterialStoring {
    let engine: ProvisioningEngineLive
    let operation: UUID
    let account: String
    let team: String
    func loadPending() async throws -> PendingSigningMaterial? {
        try await engine.loadPending(operation: operation, account: account, team: team)
    }
    func savePending(_ material: PendingSigningMaterial) async throws {
        try await engine.savePending(material, operation: operation, account: account, team: team)
    }
    func invalidateCertificate(id: String) async throws {
        try await engine.invalidateCertificate(id, operation: operation, account: account, team: team)
    }
}
