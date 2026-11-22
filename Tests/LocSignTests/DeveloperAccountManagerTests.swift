import XCTest
@testable import LocSign

final class DeveloperAccountManagerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let day: TimeInterval = 86_400

    func testOverviewSortsGroupsMarksLocalCertificatesAndNeverMutates() async throws {
        let log = AccountEventLog()
        let gateway = AccountGatewayFixture(log: log, now: now)
        let store = AccountStoreFixture(log: log, pendingCertificateID: "cert-pending")
        let overview = try await manager(gateway, store).overview(localCertificateIDs: ["cert-active"])

        XCTAssertEqual(overview.certificates.map(\.id), ["cert-pending", "cert-active", "cert-other"])
        XCTAssertEqual(overview.certificates.map(\.usedByLocSign), [true, true, false])
        XCTAssertEqual(overview.appIDs.map(\.identifier), ["com.example.app", "com.example.app.widget", "com.example.old"])
        XCTAssertEqual(overview.appIDs.first?.profiles.map(\.id), ["p-new", "p-old"])
        XCTAssertEqual(overview.appIDs.first?.latestProfileExpiry, now.addingTimeInterval(6 * day))
        XCTAssertEqual(overview.appIDs.last?.profiles, [])
        XCTAssertNil(overview.appIDs.last?.latestProfileExpiry)
        XCTAssertEqual(overview.devices.map(\.name), ["iPad", "iPhone"])
        XCTAssertEqual(overview.loadedAt, now)
        XCTAssertEqual(overview.recentAppIDEstimate, 1)
        XCTAssertEqual(overview.estimatedRemainingAppIDs, 9)
        let events = await log.events
        XCTAssertFalse(events.contains { $0.hasPrefix("revoke") || $0.hasPrefix("invalidate") || $0.hasPrefix("create") })
    }

    func testRecentAppIDEstimateUsesStrictSevenDayWindowAndNeverGoesNegative() {
        func app(_ id: String, created: Date?) -> DeveloperAppIDSummary {
            .init(id: id, identifier: "com.example." + id, name: id,
                  profiles: [.init(id: "p-" + id, name: id, created: created, expiry: nil, active: true)])
        }
        let edge = DeveloperAccountOverview(certificates: [], appIDs: [
            app("inside", created: now.addingTimeInterval(-7 * day + 1)),
            app("edge", created: now.addingTimeInterval(-7 * day)),
            app("unknown", created: nil),
        ], devices: [], loadedAt: now)
        XCTAssertEqual(edge.recentAppIDEstimate, 1)

        let full = DeveloperAccountOverview(certificates: [],
            appIDs: (0..<12).map { app("a\($0)", created: now.addingTimeInterval(-day)) }, devices: [], loadedAt: now)
        XCTAssertEqual(full.recentAppIDEstimate, 12)
        XCTAssertEqual(full.estimatedRemainingAppIDs, 0)
    }

    func testRevokeRechecksListThenInvalidatesLocalMaterialBeforeRevoking() async throws {
        let log = AccountEventLog()
        let gateway = AccountGatewayFixture(log: log, now: now)
        let store = AccountStoreFixture(log: log, pendingCertificateID: nil)
        let target = await gateway.certificate("cert-other").revocation
        try await manager(gateway, store).revoke(target)
        let events = await log.events
        XCTAssertEqual(events, ["list-certificates", "invalidate:cert-other", "revoke:cert-other"])
    }

    func testRevokeStopsWithoutAnyMutationWhenCertificateChanged() async throws {
        for changed in [
            CertificateRevocation(id: "cert-other", serialNumber: "FF", name: "Other", expiry: now.addingTimeInterval(300 * day)),
            CertificateRevocation(id: "cert-missing", serialNumber: "03", name: "Gone", expiry: now.addingTimeInterval(300 * day)),
        ] {
            let log = AccountEventLog()
            let gateway = AccountGatewayFixture(log: log, now: now)
            let store = AccountStoreFixture(log: log, pendingCertificateID: nil)
            do {
                try await manager(gateway, store).revoke(changed)
                XCTFail("Stale certificate revoked")
            } catch { XCTAssertEqual(error as? DeveloperServicesError, .remoteChanged) }
            let events = await log.events
            XCTAssertEqual(events, ["list-certificates"])
        }
    }

    func testRevokeCancelledAfterRecheckMakesNoMutation() async throws {
        let log = AccountEventLog()
        let gateway = AccountGatewayFixture(log: log, now: now)
        await gateway.setCancelOnList()
        let store = AccountStoreFixture(log: log, pendingCertificateID: nil)
        let target = await gateway.certificate("cert-other").revocation
        let subject = manager(gateway, store)
        let task = Task { try await subject.revoke(target) }
        do { try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await log.events
        XCTAssertEqual(events, ["list-certificates"])
    }

    func testFailedLocalInvalidationNeverRevokesRemotely() async throws {
        let log = AccountEventLog()
        let gateway = AccountGatewayFixture(log: log, now: now)
        let store = AccountStoreFixture(log: log, pendingCertificateID: nil, failInvalidation: true)
        let target = await gateway.certificate("cert-other").revocation
        do { try await manager(gateway, store).revoke(target); XCTFail("Invalidation failure ignored") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotWriteToFile) }
        let events = await log.events
        XCTAssertEqual(events, ["list-certificates", "invalidate:cert-other"])
    }

    func testDefaultGatewayOverviewFailsClosed() async {
        let gateway = MinimalGatewayFixture()
        do { _ = try await gateway.listBundleSummaries(); XCTFail("Default returned data") }
        catch { XCTAssertEqual(error as? DeveloperServicesFailure, .init(step: .listBundles, reason: .invalidResponse)) }
    }

    func testMaskedUDIDShowsOnlyTail() {
        let device = DeveloperDeviceSummary(id: "d", name: "iPhone", udid: "00008110-001A2B3C4D5E6F70",
                                            model: nil, enabled: true, added: nil)
        XCTAssertEqual(device.maskedUDID, "…5E6F70")
        XCTAssertEqual(DeveloperDeviceSummary(id: "d", name: "x", udid: "ABC", model: nil, enabled: true, added: nil).maskedUDID, "ABC")
    }

    func testRemoteChangeMessageSaysNothingWasRevoked() {
        XCTAssertTrue(DeveloperAccountModel.message(DeveloperServicesError.remoteChanged).contains("未撤销任何证书"))
        XCTAssertEqual(DeveloperAccountModel.message(CancellationError()), "操作已取消")
    }

    private func manager(_ gateway: AccountGatewayFixture, _ store: AccountStoreFixture) -> DeveloperAccountManager {
        let now = self.now
        return DeveloperAccountManager(gateway: gateway, store: store, now: { now })
    }
}

private actor AccountEventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor AccountStoreFixture: ProvisioningMaterialStoring {
    let log: AccountEventLog
    let pendingCertificateID: String?
    let failInvalidation: Bool
    init(log: AccountEventLog, pendingCertificateID: String?, failInvalidation: Bool = false) {
        self.log = log
        self.pendingCertificateID = pendingCertificateID
        self.failInvalidation = failInvalidation
    }
    func loadPending() async throws -> PendingSigningMaterial? {
        guard let pendingCertificateID else { return nil }
        return PendingSigningMaterial(privateKeyPEM: Data("synthetic".utf8), csr: "csr",
            certificate: .init(id: pendingCertificateID, serial: "01", name: "Pending", expiry: Date.distantFuture, der: nil))
    }
    func savePending(_ material: PendingSigningMaterial) async throws { await log.append("save-pending") }
    func invalidateCertificate(id: String) async throws {
        await log.append("invalidate:" + id)
        if failInvalidation { throw URLError(.cannotWriteToFile) }
    }
}

private actor AccountGatewayFixture: DeveloperServicesGateway {
    let log: AccountEventLog
    let certs: [DeveloperCertificate]
    let bundles: [DeveloperBundleSummary]
    let profiles: [String: [DeveloperProfileSummary]]
    let devices: [DeveloperDeviceSummary]
    private var cancelOnList = false

    init(log: AccountEventLog, now: Date) {
        let day: TimeInterval = 86_400
        self.log = log
        certs = [
            .init(id: "cert-other", serial: "02", name: "Other", expiry: now.addingTimeInterval(300 * day), der: nil),
            .init(id: "cert-pending", serial: "01", name: "Pending", expiry: now.addingTimeInterval(100 * day), der: nil),
            .init(id: "cert-active", serial: "04", name: "Active", expiry: now.addingTimeInterval(200 * day), der: nil),
        ]
        bundles = [
            .init(id: "b-old", identifier: "com.example.old", name: "Old"),
            .init(id: "b-app", identifier: "com.example.app", name: "App"),
            .init(id: "b-widget", identifier: "com.example.app.widget", name: "Widget"),
        ]
        profiles = [
            "b-app": [
                .init(id: "p-old", name: "old", created: now.addingTimeInterval(-6 * day), expiry: now.addingTimeInterval(day), active: true),
                .init(id: "p-new", name: "new", created: now.addingTimeInterval(-day), expiry: now.addingTimeInterval(6 * day), active: true),
            ],
            "b-widget": [
                .init(id: "p-w", name: "widget", created: now.addingTimeInterval(-8 * day), expiry: now.addingTimeInterval(-day), active: false),
            ],
        ]
        devices = [
            .init(id: "d1", name: "iPhone", udid: "SYNTHETIC-UDID-1", model: "iPhone 15", enabled: true, added: nil),
            .init(id: "d2", name: "iPad", udid: "SYNTHETIC-UDID-2", model: nil, enabled: false, added: nil),
        ]
    }
    func setCancelOnList() { cancelOnList = true }
    func certificate(_ id: String) -> DeveloperCertificate { certs.first { $0.id == id }! }

    func listBundleSummaries() async throws -> [DeveloperBundleSummary] { await log.append("list-bundles"); return bundles }
    func listProfileSummaries(bundleID: String) async throws -> [DeveloperProfileSummary] {
        await log.append("list-profiles:" + bundleID)
        return profiles[bundleID] ?? []
    }
    func listDeviceSummaries() async throws -> [DeveloperDeviceSummary] { await log.append("list-devices"); return devices }
    func listCertificates() async throws -> [DeveloperCertificate] {
        await log.append("list-certificates")
        if cancelOnList { withUnsafeCurrentTask { $0?.cancel() } }
        return certs
    }
    func revokeCertificate(id: String) async throws { await log.append("revoke:" + id) }

    func listDevices() async throws -> [DeveloperDevice] { throw DeveloperServicesError.invalidResponse }
    func registerDevice(udid: String) async throws -> DeveloperDevice {
        await log.append("create-device"); throw DeveloperServicesError.invalidResponse
    }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? { throw DeveloperServicesError.invalidResponse }
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle {
        await log.append("create-bundle"); throw DeveloperServicesError.invalidResponse
    }
    func certificateDetails(id: String) async throws -> DeveloperCertificate { throw DeveloperServicesError.invalidResponse }
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate {
        await log.append("create-certificate"); throw DeveloperServicesError.invalidResponse
    }
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] { throw DeveloperServicesError.invalidResponse }
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile {
        await log.append("create-profile"); throw DeveloperServicesError.invalidResponse
    }
}

/// Implements only the original requirements, like the older test doubles.
private struct MinimalGatewayFixture: DeveloperServicesGateway {
    func listDevices() async throws -> [DeveloperDevice] { [] }
    func registerDevice(udid: String) async throws -> DeveloperDevice { throw DeveloperServicesError.invalidResponse }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? { nil }
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle { throw DeveloperServicesError.invalidResponse }
    func listCertificates() async throws -> [DeveloperCertificate] { [] }
    func certificateDetails(id: String) async throws -> DeveloperCertificate { throw DeveloperServicesError.invalidResponse }
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate { throw DeveloperServicesError.invalidResponse }
    func revokeCertificate(id: String) async throws {}
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] { [] }
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile {
        throw DeveloperServicesError.invalidResponse
    }
}
