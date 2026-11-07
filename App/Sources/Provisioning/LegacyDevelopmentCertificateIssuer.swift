import Foundation
import XKit
import Dependencies

struct LegacyDevelopmentCertificateIssuer: Sendable {
    let auth: XcodeAuthData
    let provider: any AnisetteDataProvider
    let client: any HTTPClientProtocol

    func issue(csr: String) async throws -> Data {
        do {
            try Task.checkCancellation()
            let result = try await withDependencies {
                $0.httpClient = client
                $0.anisetteDataProvider = provider
            } operation: {
                try await DeveloperServicesClient(authData: auth).send(DevelopmentCSRRequest(team: auth.teamID.rawValue, csr: csr))
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? DeveloperServicesAPIVersionLegacy.Error {
                throw failure.code == 7460 ? DeveloperServicesError.certificateQuota : .appleRejected(failure.code)
            }
            if let failure = error as? HTTPResponseError { throw DeveloperServicesError.rejected(failure.status.code) }
            if error is ProvisioningNetworkError || error is URLError {
                throw DeveloperServicesError.network
            }
            throw DeveloperServicesError.invalidResponse
        }
    }
}

private struct DevelopmentCSRRequest: DeveloperServicesRequest {
    struct Response: Decodable, Sendable {
        struct Certificate: Decodable, Sendable {
            let certContent: Data
            enum CodingKeys: String, CodingKey { case certContent }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let data = try? values.decode(Data.self, forKey: .certContent) { certContent = data }
                else {
                    let value = try values.decode(String.self, forKey: .certContent)
                    guard let data = Data(base64Encoded: value), !data.isEmpty else { throw DeveloperServicesError.invalidResponse }
                    certContent = data
                }
            }
        }
        let certRequest: Certificate
    }
    typealias Value = Data
    let team: String
    let csr: String
    var action: String { "ios/submitDevelopmentCSR" }
    var parameters: [String: Any] {
        ["teamId": team, "csrContent": csr, "machineId": "LocSign", "machineName": "LocSign"]
    }
    func parse(_ response: Response) async throws -> Data {
        guard !response.certRequest.certContent.isEmpty else { throw DeveloperServicesError.invalidResponse }
        return response.certRequest.certContent
    }
}
