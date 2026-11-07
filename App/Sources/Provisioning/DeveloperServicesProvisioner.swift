import Foundation

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

    var errorDescription: String? {
        switch self {
        case .certificateQuota: return "Apple 开发者服务拒绝申请：开发证书数量已达上限"
        case .rejected(let status): return "Apple Developer Services 请求被拒绝（HTTP \(status)）"
        case .appleRejected(let code): return "Apple Developer Services 请求被拒绝（Apple \(code)）"
        case .invalidResponse: return "Apple Developer Services 返回的数据无效，无法继续申请材料"
        case .remoteChanged: return "Apple Developer Services 证书列表发生变化，请重新申请"
        case .network: return "网络连接失败，请检查连接后重试"
        case .registrationRejected(let status, let reason): return "\(reason.message)（HTTP \(status)）"
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
    case createCertificate = "申请开发证书"
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
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate
    func revokeCertificate(id: String) async throws
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile]
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile
}

struct PendingSigningMaterial: Codable, Sendable {
    let privateKeyPEM: Data
    let csr: String
    var certificate: DeveloperCertificate?
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
           let recovered = certificates.first(where: { certificate in
               guard certificate.expiry > now(), let der = certificate.der else { return false }
               return LocSignVerifyProvisioningCertificate(der, saved.privateKeyPEM, now()) != nil
           }) {
            saved.certificate = recovered
            try await store.savePending(saved)
            pending = saved
            reusable = recovered
        }
        if reusable == nil {
            // A key saved before a failed CSR request remains the only candidate
            // for recovery; otherwise create a fresh, durable pending identity.
            if pending == nil || pending?.certificate != nil { pending = try keys.generate() }
            guard var identity = pending else { throw DeveloperServicesError.invalidResponse }
            try Task.checkCancellation()
            try await store.savePending(identity)
            let issued: DeveloperCertificate
            do { issued = try await gateway.createDevelopmentCertificate(csr: identity.csr) }
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
                issued = try await gateway.createDevelopmentCertificate(csr: identity.csr)
            }
            guard issued.expiry > now(), let der = issued.der,
                  LocSignVerifyProvisioningCertificate(der, identity.privateKeyPEM, now()) != nil else { throw ProfileValidationError.certificate }
            identity.certificate = issued
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
        let profile = try await gateway.createDevelopmentProfile(bundleID: bundle.id, certificateID: certificate.id, deviceID: device.id)
        try Task.checkCancellation()
        return try validate(profile)
    }
}
