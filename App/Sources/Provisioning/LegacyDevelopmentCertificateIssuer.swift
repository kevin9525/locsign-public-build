import Foundation
import XKit

struct LegacyDevelopmentCertificateIssuer: Sendable {
    let auth: XcodeAuthData
    let provider: any AnisetteDataProvider
    let client: any HTTPClientProtocol

    func issue(csr: String) async throws -> Data { throw DeveloperServicesError.invalidResponse }
}
