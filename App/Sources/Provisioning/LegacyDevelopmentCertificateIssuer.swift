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
            if let failure = error as? DeveloperServicesError { throw failure }
            if error is DecodingError { throw DeveloperServicesError.certificateResponse(.envelope) }
            throw DeveloperServicesError.invalidResponse
        }
    }
}

private struct DevelopmentCSRRequest: DeveloperServicesRequest {
    struct Response: Decodable, Sendable {
        struct Certificate: Decodable, Sendable {
            let certContent: Data
            enum CodingKeys: String, CodingKey { case certContent, certificateContent }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let keys: [CodingKeys] = [.certContent, .certificateContent].filter { values.contains($0) }
                guard !keys.isEmpty else { throw DeveloperServicesError.certificateResponse(.missingContent) }
                guard keys.count == 1, let key = keys.first else { throw DeveloperServicesError.certificateResponse(.ambiguousContent) }
                if let data = try? values.decode(Data.self, forKey: key) { certContent = data }
                else if let text = try? values.decode(String.self, forKey: key) { certContent = Data(text.utf8) }
                else { throw DeveloperServicesError.certificateResponse(.contentType) }
            }
        }
        let certRequest: Certificate
        enum CodingKeys: String, CodingKey { case certRequest }
        init(from decoder: Decoder) throws {
            do {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                certRequest = try values.decode(Certificate.self, forKey: .certRequest)
            } catch let failure as DeveloperServicesError { throw failure }
            catch { throw DeveloperServicesError.certificateResponse(.missingRequest) }
        }
    }
    typealias Value = Data
    let team: String
    let csr: String
    var action: String { "ios/submitDevelopmentCSR" }
    var parameters: [String: Any] {
        ["teamId": team, "csrContent": csr, "machineId": "LocSign", "machineName": "LocSign"]
    }
    func parse(_ response: Response) async throws -> Data {
        try CertificateResponseDecoder.decode(response.certRequest.certContent)
    }
}
