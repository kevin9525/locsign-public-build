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
    private var currentEngine: (any ProvisioningEngine)?
    private var configuration: AnisetteProviderConfiguration?
    private var generation = UUID()
    private var codeContinuation: CheckedContinuation<String?, Never>?
    private var revocationContinuation: CheckedContinuation<Bool, Never>?

    init(factory: EngineFactory? = nil) {
        self.factory = factory ?? { try ProvisioningEngineLive.live(configuration: $0) }
    }
    var engine: (any ProvisioningEngine)? { currentEngine }

    private func configuredEngine() throws -> any ProvisioningEngine {
        guard providerEnabled, providerAccepted else { throw ProvisioningError.providerUnavailable("请启用并确认所选提供方") }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProvisioningError.providerUnavailable("请输入有效的 HTTPS 提供方地址")
        }
        let proposed = try AnisetteProviderConfiguration(endpoint: url)
        if let currentEngine, configuration == proposed { return currentEngine }
        let engine = try factory(proposed)
        configuration = proposed
        currentEngine = engine
        return engine
    }

    func restore() async {
        guard !isBusy, account == nil, providerEnabled, providerAccepted else { return }
        let operation = generation
        isBusy = true
        defer { if generation == operation { isBusy = false } }
        do {
            let engine = try configuredEngine()
            let restored = try await engine.restoreAccount()
            try check(operation)
            setAccount(restored)
        } catch { if generation == operation { self.error = message(error) } }
    }

    func logIn() async {
        guard !isBusy else { return }
        let secret = password
        password = ""
        generation = UUID()
        let operation = generation
        isBusy = true
        error = nil
        defer { if generation == operation { isBusy = false } }
        do {
            let engine = try configuredEngine()
            let result = try await engine.logIn(appleID: appleID, password: secret, twoFactorCode: { [weak self] in
                await self?.requestCode(operation: operation)
            })
            try check(operation)
            guard !result.teams.isEmpty else { throw AppleAccountError.noDeveloperTeam }
            setAccount(result)
        } catch { if generation == operation { self.error = message(error) } }
    }

    private func setAccount(_ value: ProvisioningAccount?) {
        account = value
        teamID = value?.teams.count == 1 ? (value?.teams.first?.id ?? "") : ""
        if let value { appleID = value.appleID }
    }

    private func requestCode(operation: UUID) async -> String? {
        guard generation == operation, !Task.isCancelled, codeContinuation == nil else { return nil }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard generation == operation, !Task.isCancelled else { continuation.resume(returning: nil); return }
                code = ""
                awaitingCode = true
                codeContinuation = continuation
            }
        }, onCancel: { Task { @MainActor [weak self] in
            guard let self, self.generation == operation else { return }
            self.resolveCode(nil)
        } })
    }
    func submitCode() {
        let submitted = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard submitted.utf8.count == 6, submitted.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        resolveCode(submitted)
    }
    private func resolveCode(_ value: String?) {
        let continuation = codeContinuation
        codeContinuation = nil
        awaitingCode = false
        code = ""
        continuation?.resume(returning: value)
    }
    func cancel() async {
        generation = UUID()
        password = ""
        resolveCode(nil)
        resolveRevocation(false)
        isBusy = false
        await currentEngine?.cancel()
    }
    func logout() async {
        let identity = account?.appleID ?? appleID
        await cancel()
        do {
            try await currentEngine?.logout(account: identity)
            setAccount(nil)
            error = nil
        } catch { self.error = message(error) }
    }
    func confirmRevocation(_ candidates: [CertificateRevocation]) async -> Bool {
        guard !Task.isCancelled, providerAccepted, providerEnabled, !candidates.isEmpty, revocationContinuation == nil else { return false }
        let operation = generation
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard generation == operation, !Task.isCancelled else { continuation.resume(returning: false); return }
                revocations = candidates
                revocationContinuation = continuation
            }
        }, onCancel: { Task { @MainActor [weak self] in
            guard let self, self.generation == operation else { return }
            self.resolveRevocation(false)
        } })
    }
    func resolveRevocation(_ confirmed: Bool) {
        let continuation = revocationContinuation
        revocationContinuation = nil
        revocations = []
        continuation?.resume(returning: confirmed)
    }
    func changeProvider() async {
        let previous = currentEngine
        currentEngine = nil
        configuration = nil
        providerAccepted = false
        setAccount(nil)
        await cancel()
        await previous?.cancel()
        // Restore only inspects local Keychain state. It removes a session/ADI
        // from another provider and preserves the stable signing-key namespace.
        if providerEnabled, let url = URL(string: endpoint), let config = try? AnisetteProviderConfiguration(endpoint: url) {
            do {
                let replacement = try factory(config)
                _ = try await replacement.restoreAccount()
                await replacement.cancel()
            } catch { self.error = message(error) }
        }
    }
    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard generation == operation else { throw CancellationError() }
    }
    private func message(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消" }
        return ProvisioningRedaction.redact(error.localizedDescription)
    }
}
