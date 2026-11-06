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
enum DeveloperServicesError: Error, Equatable { case certificateQuota, rejected(Int), invalidResponse, remoteChanged }

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
        throw DeveloperServicesError.invalidResponse
    }
}
