import Foundation
import XKit

struct DeveloperDevice: Sendable, Equatable { let id: String; let udid: String; let enabled: Bool }
struct DeveloperBundle: Sendable, Equatable { let id: String; let identifier: String; let capabilities: [String] }
struct DeveloperCertificate: Codable, Sendable, Equatable {
    let id: String
    let serial: String
    let name: String
    let expiry: Date
    let der: Data?
    var revocation: CertificateRevocation { .init(id: id, serialNumber: serial, name: name, expiry: expiry) }
}
struct DeveloperProfile: Sendable { let id: String; let content: Data }
enum DeveloperServicesError: LocalizedError, Equatable {
    case certificateQuota, rejected(Int), appleRejected(Int), invalidResponse, remoteChanged, network
    case registrationRejected(Int, DeveloperRegistrationReason)
    case profileRejected(Int, DeveloperProfileReason)
    case certificateResponse(CertificateResponseProblem), issuedCertificateMissing, issuedCertificateConflict
    case certificateRecoveryPending

    var errorDescription: String? {
        switch self {
        case .certificateQuota: return "Apple 开发者服务拒绝申请：开发证书数量已达上限"
        case .rejected(let status): return "Apple Developer Services 请求被拒绝（HTTP \(status)）"
        case .appleRejected(let code): return "Apple Developer Services 请求被拒绝（Apple \(code)）"
        case .invalidResponse: return "Apple Developer Services 返回的数据无效，无法继续申请材料"
        case .remoteChanged: return "Apple Developer Services 证书列表发生变化，请重新申请"
        case .network: return "网络连接失败，请检查连接后重试"
        case .registrationRejected(let status, let reason): return "\(reason.message)（HTTP \(status)）"
        case .profileRejected(let status, let reason): return "\(reason.message)（HTTP \(status)）"
        case .certificateResponse(let problem): return "证书签发响应：\(problem.message)"
        case .issuedCertificateMissing: return "已收到签发证书，但 Apple 证书列表中尚未找到对应记录"
        case .issuedCertificateConflict: return "Apple 证书列表中的匹配记录不唯一或证书内容不一致，已停止使用"
        case .certificateRecoveryPending: return "证书申请结果尚待确认，查询中尚未取得与当前私钥匹配的有效证书。申请材料已保留，可稍后重试查询；重试不会重复申请或撤销证书"
        }
    }
}

enum DeveloperServicesStep: String, Sendable {
    case listDevices = "查询设备"
    case registerDevice = "注册设备"
    case findBundle = "查询应用标识"
    case createBundle = "注册应用标识"
    case readCapabilities = "查询应用权限"
    case listCertificates = "查询开发证书"
    case readCertificate = "读取开发证书内容"
    case createCertificate = "申请开发证书"
    case resolveCertificate = "匹配已签发证书"
    case revokeCertificate = "撤销开发证书"
    case listProfiles = "查询描述文件"
    case createProfile = "创建描述文件"
}

// Only fixed operation names and safe error values cross the UI boundary.
// Raw OpenAPI errors can contain headers, request bodies and server responses.
struct DeveloperServicesFailure: LocalizedError, Equatable {
    let step: DeveloperServicesStep
    let reason: DeveloperServicesError
    var errorDescription: String? { "\(step.rawValue)失败：\(reason.localizedDescription)" }
}

protocol DeveloperServicesGateway: Sendable {
    func listDevices() async throws -> [DeveloperDevice]
    func registerDevice(udid: String) async throws -> DeveloperDevice
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle?
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle
    func listCertificates() async throws -> [DeveloperCertificate]
    func certificateDetails(id: String) async throws -> DeveloperCertificate
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate
    func revokeCertificate(id: String) async throws
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile]
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile
}

struct PendingSigningMaterial: Codable, Sendable {
    let privateKeyPEM: Data
    let csr: String
    var certificate: DeveloperCertificate?
    // Optional for compatibility with previously saved pending keys.
    var awaitingCertificate: Bool? = nil
}
protocol ProvisioningMaterialStoring: Sendable {
    func loadPending() async throws -> PendingSigningMaterial?
    func savePending(_ material: PendingSigningMaterial) async throws
    func invalidateCertificate(id: String) async throws
}
protocol ProvisioningKeyGenerating: Sendable { func generate() throws -> PendingSigningMaterial }

struct DeveloperServicesProvisioner: Sendable {
    let gateway: any DeveloperServicesGateway
    let store: any ProvisioningMaterialStoring
    let keys: any ProvisioningKeyGenerating
    let anchors: [Data]
    let now: @Sendable () -> Date

    func provision(app: ProvisioningApp, deviceUDID: String, teamID: String,
                   confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        try Task.checkCancellation()
        guard !app.bundleID.isEmpty, !deviceUDID.isEmpty, !teamID.isEmpty else { throw DeveloperServicesError.invalidResponse }
        // Read and reject incompatible existing App IDs before any remote mutation.
        let existingBundle = try await gateway.findExactBundleID(app.bundleID)
        if let existingBundle {
            guard existingBundle.identifier == app.bundleID,
                  Set(existingBundle.capabilities).isSubset(of: ["IN_APP_PURCHASE"]) else {
                throw ProvisioningError.unsupportedIPA("现有 App ID 包含不支持的权限，未修改远端配置")
            }
        }
        let devices = try await gateway.listDevices()
        try Task.checkCancellation()
        let device: DeveloperDevice
        if let registered = devices.first(where: { $0.udid == deviceUDID }) {
            guard registered.enabled else { throw ProvisioningError.remote("所选设备已被停用") }
            device = registered
        } else { device = try await gateway.registerDevice(udid: deviceUDID) }
        guard device.enabled, device.udid == deviceUDID else { throw DeveloperServicesError.invalidResponse }
        try Task.checkCancellation()
        let bundle: DeveloperBundle
        if let existingBundle { bundle = existingBundle }
        else { bundle = try await gateway.createBundleID(app.bundleID, name: app.name) }
        guard bundle.identifier == app.bundleID,
              Set(bundle.capabilities).isSubset(of: ["IN_APP_PURCHASE"]) else { throw DeveloperServicesError.invalidResponse }

        let certificates = try await gateway.listCertificates()
        var pending = try await store.loadPending()
        var reusable: DeveloperCertificate?
        if let saved = pending, let local = saved.certificate,
           let remote = certificates.first(where: { $0.id == local.id && $0.serial == local.serial }),
           remote.expiry > now(), let der = remote.der ?? local.der,
           LocSignVerifyProvisioningCertificate(der, saved.privateKeyPEM, now()) != nil {
            reusable = DeveloperCertificate(id: remote.id, serial: remote.serial, name: remote.name, expiry: remote.expiry, der: der)
        }
        if var saved = pending, saved.certificate == nil,
           let recovered = try await recoverCertificate(for: saved, from: certificates) {
            saved.certificate = recovered
            saved.awaitingCertificate = false
            try await store.savePending(saved)
            pending = saved
            reusable = recovered
        }
        if reusable == nil {
            guard pending?.awaitingCertificate != true else { throw DeveloperServicesError.certificateRecoveryPending }
            // A key saved before a failed CSR request remains the only candidate
            // for recovery; otherwise create a fresh, durable pending identity.
            if pending == nil || pending?.certificate != nil { pending = try keys.generate() }
            guard var identity = pending else { throw DeveloperServicesError.invalidResponse }
            try Task.checkCancellation()
            let issued: DeveloperCertificate
            do { issued = try await issueOrRecover(identity) }
            catch DeveloperServicesError.certificateQuota {
                let candidates = try await gateway.listCertificates().sorted { $0.id < $1.id }
                guard !candidates.isEmpty else { throw DeveloperServicesError.certificateQuota }
                try Task.checkCancellation()
                guard await confirmRevocation(candidates.map(\.revocation)) else { throw ProvisioningError.revocationDeclined }
                try Task.checkCancellation()
                let fresh = try await gateway.listCertificates().sorted { $0.id < $1.id }
                guard fresh.map(\.revocation) == candidates.map(\.revocation) else { throw DeveloperServicesError.remoteChanged }
                for certificate in candidates {
                    try Task.checkCancellation()
                    try await store.invalidateCertificate(id: certificate.id)
                    try Task.checkCancellation()
                    try await gateway.revokeCertificate(id: certificate.id)
                }
                try Task.checkCancellation()
                issued = try await issueOrRecover(identity)
            }
            guard issued.expiry > now(), let der = issued.der,
                  LocSignVerifyProvisioningCertificate(der, identity.privateKeyPEM, now()) != nil else { throw ProfileValidationError.certificate }
            identity.certificate = issued
            identity.awaitingCertificate = false
            // Preserve an issued certificate/key even if the profile request fails.
            try await store.savePending(identity)
            pending = identity
            reusable = issued
        }
        guard let identity = pending, let certificate = reusable, let der = certificate.der,
              let pem = String(data: identity.privateKeyPEM, encoding: .utf8) else { throw DeveloperServicesError.invalidResponse }
        let validator = ProvisioningProfileValidator(trustAnchors: anchors, now: now())
        func validate(_ profile: DeveloperProfile) throws -> ProvisioningMaterial {
            let validated = try validator.validate(data: profile.content, expectedBundleID: app.bundleID,
                expectedTeamID: teamID, expectedUDID: deviceUDID, expectedCertificateDER: der, privateKeyPEM: identity.privateKeyPEM)
            return ProvisioningMaterial(privateKeyPEM: pem, profileData: validated.raw,
                certificateExpiry: min(certificate.expiry, validated.certificateExpiry), profileExpiry: validated.expiry)
        }
        for profile in try await gateway.listProfiles(bundleID: bundle.id) {
            try Task.checkCancellation()
            if let material = try? validate(profile) { return material }
        }
        try Task.checkCancellation()
        let profile: DeveloperProfile
        do {
            profile = try await gateway.createDevelopmentProfile(bundleID: bundle.id, certificateID: certificate.id, deviceID: device.id)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let originalError = error
            let failure = error as? DeveloperServicesFailure
            let reason = failure?.reason ?? (error as? DeveloperServicesError)
            let conflict: Bool
            switch reason {
            case .rejected(409)?, .profileRejected(409, _)?: conflict = true
            default: conflict = false
            }
            guard conflict, failure == nil || failure?.step == .createProfile else { throw error }
            // Another request may have completed since the earlier list. Read
            // once, validate exactly as normal, and never delete/recreate here.
            do {
                for candidate in try await gateway.listProfiles(bundleID: bundle.id) {
                    try Task.checkCancellation()
                    if let material = try? validate(candidate) { return material }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // A failed lookup must not hide the actual creation rejection.
            }
            try Task.checkCancellation()
            throw originalError
        }
        try Task.checkCancellation()
        return try validate(profile)
    }

    private func issueOrRecover(_ identity: PendingSigningMaterial) async throws -> DeveloperCertificate {
        var pending = identity
        pending.awaitingCertificate = true
        // Commit uncertainty before the remote mutation. The guarded store rejects
        // late writes after cancellation, so a response-time commit is too late.
        try await store.savePending(pending)
        try Task.checkCancellation()
        do { return try await gateway.createDevelopmentCertificate(csr: identity.csr) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = error as? DeveloperServicesFailure
            let reason = failure?.reason ?? (error as? DeveloperServicesError)
            // The gateway also reads certificates after issuance. A rejected read
            // cannot prove the CSR was rejected; retain the marker in that case.
            if failure == nil || failure?.step == .createCertificate {
                let definitelyRejected: Bool
                switch reason {
                case .certificateQuota?, .appleRejected(_)?: definitelyRejected = true
                case .rejected(let status)?: definitelyRejected = (400..<500).contains(status) && status != 408
                default: definitelyRejected = false
                }
                if definitelyRejected {
                    pending.awaitingCertificate = false
                    try await store.savePending(pending)
                    throw error
                }
            }
            guard reason == .certificateResponse(.missingContent) else { throw error }
            try Task.checkCancellation()
            let certificates = try await gateway.listCertificates()
            guard let certificate = try await recoverCertificate(for: pending, from: certificates) else {
                throw DeveloperServicesError.certificateRecoveryPending
            }
            return certificate
        }
    }

    private func recoverCertificate(for pending: PendingSigningMaterial,
                                    from certificates: [DeveloperCertificate]) async throws -> DeveloperCertificate? {
        var matches: [DeveloperCertificate] = []
        for listed in certificates where listed.expiry > now() {
            try Task.checkCancellation()
            let candidate = listed.der == nil ? try await gateway.certificateDetails(id: listed.id) : listed
            try Task.checkCancellation()
            guard candidate.id == listed.id,
                  candidate.serial.uppercased().drop(while: { $0 == "0" }) == listed.serial.uppercased().drop(while: { $0 == "0" }) else {
                throw DeveloperServicesError.remoteChanged
            }
            guard candidate.expiry > now(), let der = candidate.der else { continue }
            guard let parsed = try? XKit.Certificate(data: der), parsed.hasSerialNumber(candidate.serial) else {
                throw DeveloperServicesError.remoteChanged
            }
            guard LocSignVerifyProvisioningCertificate(der, pending.privateKeyPEM, now()) != nil else { continue }
            matches.append(.init(id: candidate.id, serial: candidate.serial, name: candidate.name,
                                 expiry: min(listed.expiry, candidate.expiry), der: der))
        }
        guard matches.count <= 1 else { throw DeveloperServicesError.issuedCertificateConflict }
        return matches.first
    }
}
