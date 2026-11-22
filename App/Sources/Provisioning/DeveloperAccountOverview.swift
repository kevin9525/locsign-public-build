import Foundation

// Read-only views of the Apple developer account for the certificate
// management page. None of these values carry key material or profile bytes.

struct DeveloperBundleSummary: Sendable, Equatable {
    let id: String
    let identifier: String
    let name: String
}

struct DeveloperProfileSummary: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let created: Date?
    let expiry: Date?
    let active: Bool
}

struct DeveloperDeviceSummary: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let udid: String
    let model: String?
    let enabled: Bool
    let added: Date?

    /// UDIDs identify a physical device; the page only shows the tail.
    var maskedUDID: String { udid.count > 6 ? "…" + udid.suffix(6) : udid }
}

struct DeveloperCertificateSummary: Sendable, Equatable, Identifiable {
    let certificate: CertificateRevocation
    /// LocSign's saved pending or active signing material uses this certificate.
    let usedByLocSign: Bool
    var id: String { certificate.id }
}

struct DeveloperAppIDSummary: Sendable, Equatable, Identifiable {
    let id: String
    let identifier: String
    let name: String
    /// Sorted with the latest expiry first.
    let profiles: [DeveloperProfileSummary]

    var latestProfileExpiry: Date? { profiles.compactMap(\.expiry).max() }
}

struct DeveloperAccountOverview: Sendable, Equatable {
    /// Free accounts may register at most 10 App IDs in any rolling 7 days.
    static let freeAppIDLimit = 10
    static let quotaWindow: TimeInterval = 7 * 86_400

    let certificates: [DeveloperCertificateSummary]
    let appIDs: [DeveloperAppIDSummary]
    let devices: [DeveloperDeviceSummary]
    let loadedAt: Date

    /// Apple does not expose App ID registration dates. This counts App IDs
    /// with a profile created inside the 7-day window and is only an estimate.
    var recentAppIDEstimate: Int {
        appIDs.filter { app in
            app.profiles.contains { profile in
                guard let created = profile.created else { return false }
                return loadedAt.timeIntervalSince(created) < Self.quotaWindow
            }
        }.count
    }
    var estimatedRemainingAppIDs: Int { max(0, Self.freeAppIDLimit - recentAppIDEstimate) }
}

/// Reads the account overview and revokes one certificate at a time. Reads
/// never mutate. Revocation re-reads Apple's list first and stops if the
/// target changed, then drops local use before the remote revocation (the
/// same order as quota recovery in `DeveloperServicesProvisioner`).
struct DeveloperAccountManager: Sendable {
    let gateway: any DeveloperServicesGateway
    let store: any ProvisioningMaterialStoring
    let now: @Sendable () -> Date

    func overview(localCertificateIDs: Set<String>) async throws -> DeveloperAccountOverview {
        try Task.checkCancellation()
        var local = localCertificateIDs
        if let id = try await store.loadPending()?.certificate?.id { local.insert(id) }
        try Task.checkCancellation()
        let certificates = try await gateway.listCertificates()
        try Task.checkCancellation()
        let bundles = try await gateway.listBundleSummaries()
        var appIDs: [DeveloperAppIDSummary] = []
        for bundle in bundles.sorted(by: { $0.identifier < $1.identifier }) {
            try Task.checkCancellation()
            let profiles = try await gateway.listProfileSummaries(bundleID: bundle.id)
            appIDs.append(.init(id: bundle.id, identifier: bundle.identifier, name: bundle.name,
                profiles: profiles.sorted { ($0.expiry ?? .distantPast) > ($1.expiry ?? .distantPast) }))
        }
        try Task.checkCancellation()
        let devices = try await gateway.listDeviceSummaries()
        try Task.checkCancellation()
        return DeveloperAccountOverview(
            certificates: certificates.sorted { ($0.expiry, $0.id) < ($1.expiry, $1.id) }
                .map { .init(certificate: $0.revocation, usedByLocSign: local.contains($0.id)) },
            appIDs: appIDs,
            devices: devices.sorted { ($0.name, $0.id) < ($1.name, $1.id) },
            loadedAt: now())
    }

    func revoke(_ target: CertificateRevocation) async throws {
        try Task.checkCancellation()
        // Never revoke from the list the user looked at; confirm it still matches.
        let current = try await gateway.listCertificates()
        guard current.contains(where: { $0.revocation == target }) else { throw DeveloperServicesError.remoteChanged }
        try Task.checkCancellation()
        // A revoked certificate must never be offered for reuse, even if the
        // revocation response is lost. Invalidate local material first.
        try await store.invalidateCertificate(id: target.id)
        try Task.checkCancellation()
        try await gateway.revokeCertificate(id: target.id)
    }
}

// Defaults keep existing test doubles compiling. The live gateway implements all.
extension DeveloperServicesGateway {
    func listBundleSummaries() async throws -> [DeveloperBundleSummary] {
        throw DeveloperServicesFailure(step: .listBundles, reason: .invalidResponse)
    }
    func listProfileSummaries(bundleID: String) async throws -> [DeveloperProfileSummary] {
        throw DeveloperServicesFailure(step: .listProfiles, reason: .invalidResponse)
    }
    func listDeviceSummaries() async throws -> [DeveloperDeviceSummary] {
        throw DeveloperServicesFailure(step: .listDevices, reason: .invalidResponse)
    }
}
