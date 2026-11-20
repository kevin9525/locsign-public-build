import Foundation
import XKit
import Dependencies

/// Read-only compatibility path for an unreadable REST capability relationship.
struct LegacyBundleCapabilityReader: Sendable {
    let auth: XcodeAuthData
    let provider: any AnisetteDataProvider
    let client: any HTTPClientProtocol

    func capabilities(resourceID: String, identifier: String) async throws -> [String] {
        do {
            try Task.checkCancellation()
            let result = try await withDependencies {
                $0.httpClient = client
                $0.anisetteDataProvider = provider
            } operation: {
                try await DeveloperServicesClient(authData: auth).send(BundleCapabilitiesRequest(
                    team: auth.teamID.rawValue, resourceID: resourceID, identifier: identifier))
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? DeveloperServicesAPIVersionLegacy.Error {
                // This is a read, not certificate issuance; no quota/revocation flow.
                throw DeveloperServicesError.appleRejected(failure.code)
            }
            if let failure = error as? HTTPResponseError { throw DeveloperServicesError.rejected(failure.status.code) }
            if error is ProvisioningNetworkError || error is URLError { throw DeveloperServicesError.network }
            if let failure = error as? DeveloperServicesError { throw failure }
            throw DeveloperServicesError.capabilityVerificationFailed
        }
    }
}

private struct BundleCapabilitiesRequest: DeveloperServicesRequest {
    struct Response: Decodable, Sendable {
        struct App: Decodable, Sendable {
            let appIdId: String
            let identifier: String
            let enabledFeatures: [String]?
        }
        let appIds: [App]
    }
    typealias Value = [String]
    let team: String
    let resourceID: String
    let identifier: String
    var action: String { "ios/listAppIds" }
    var parameters: [String: Any] { ["teamId": team] }

    func parse(_ response: Response) async throws -> [String] {
        let matches = response.appIds.filter { $0.identifier == identifier }
        guard matches.count == 1, let app = matches.first, app.appIdId == resourceID,
              !resourceID.isEmpty, !identifier.isEmpty, let features = app.enabledFeatures,
              features.allSatisfy({ !$0.isEmpty }) else {
            throw DeveloperServicesError.capabilityVerificationFailed
        }
        return Array(Set(features.map { feature in
            switch feature {
            case "inAppPurchase", "IN_APP_PURCHASE": return "IN_APP_PURCHASE"
            case "APG3427HIY", "APP_GROUPS": return "APP_GROUPS"
            // Keep every unrecognized feature unsupported by the provisioner.
            // Do not discard it because its legacy name lacks a known mapping.
            default: return "LEGACY:" + feature
            }
        })).sorted()
    }
}
