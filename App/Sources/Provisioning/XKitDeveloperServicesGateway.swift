import Foundation
import XKit

struct XKitDeveloperServicesGateway: DeveloperServicesGateway {
    let auth: XcodeAuthData
    let provider: any AnisetteDataProvider
    let client: any HTTPClientProtocol

    func listDevices() async throws -> [DeveloperDevice] { throw DeveloperServicesError.invalidResponse }
    func registerDevice(udid: String) async throws -> DeveloperDevice { throw DeveloperServicesError.invalidResponse }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? { throw DeveloperServicesError.invalidResponse }
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle { throw DeveloperServicesError.invalidResponse }
    func listCertificates() async throws -> [DeveloperCertificate] { throw DeveloperServicesError.invalidResponse }
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate { throw DeveloperServicesError.invalidResponse }
    func revokeCertificate(id: String) async throws { throw DeveloperServicesError.invalidResponse }
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] { throw DeveloperServicesError.invalidResponse }
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile { throw DeveloperServicesError.invalidResponse }
}
