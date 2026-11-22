import XCTest
import ZIPFoundation
@testable import LocSign

/// App extensions: preflight limits, identifier retargeting, and one App ID +
/// one profile per extension bound to the app's certificate and device.
final class AppExtensionProvisioningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixtureProfileExpiry = Date(timeIntervalSince1970: 4_070_908_800)

    // MARK: Preflight

    func testAcceptsExtensionsInPlugInsAndReportsTheirIdentifiers() throws {
        let ipa = try archive(extensions: [
            .init(path: "PlugIns/Widget.appex", bundleID: "com.test.app.widget", name: "Widget"),
            .init(path: "PlugIns/Share.appex", bundleID: "com.test.app.share", name: "Share")
        ])
        let app = try ProvisioningIPAPreflight().inspect(ipa)
        XCTAssertEqual(app.bundleID, "com.test.app")
        XCTAssertEqual(app.extensions, [.init(bundleID: "com.test.app.share", name: "Share"),
                                        .init(bundleID: "com.test.app.widget", name: "Widget")])
    }

    func testRejectsExtensionsOutsideTheSupportedShape() throws {
        let invalid: [[ExtensionSpec]] = [
            [.init(path: "PlugIns/Widget.appex", bundleID: "com.other.widget")],              // foreign namespace
            [.init(path: "PlugIns/Widget.appex", bundleID: "com.test.app")],                  // same as the app
            [.init(path: "PlugIns/Widget.appex", bundleID: "com.test.app.widget", packageType: "APPL")],
            [.init(path: "plugins/Widget.appex", bundleID: "com.test.app.widget")],           // wrong directory case
            [.init(path: "Extensions/Kit.appex", bundleID: "com.test.app.kit")],              // ExtensionKit
            [.init(path: "PlugIns/Widget.appex", bundleID: "com.test.app.widget"),
             .init(path: "PlugIns/Widget.appex/PlugIns/Inner.appex", bundleID: "com.test.app.widget.inner")],
            [.init(path: "Watch/Watch.app", bundleID: "com.test.app.watch", packageType: "APPL")],
            [.init(path: "PlugIns/A.appex", bundleID: "com.test.app.same"),
             .init(path: "PlugIns/B.appex", bundleID: "com.test.app.same")],
            [.init(path: "PlugIns/Widget.appex", bundleID: "com.test.app.widget",
                   executable: ProvisioningIPAPreflightTests.macho(encrypted: true))],
            [.init(path: "PlugIns/Widget.appex", bundleID: "com.test.app.widget",
                   executable: ProvisioningIPAPreflightTests.macho(entitlements: ["aps-environment": "development"]))]
        ]
        for specs in invalid {
            XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(extensions: specs)), "\(specs.map(\.path))")
        }
    }

    func testRejectsMoreExtensionsThanTheWeeklyAppIDQuotaAllows() throws {
        let many = (0...ProvisioningIPAPreflight.maximumExtensions).map {
            ExtensionSpec(path: "PlugIns/E\($0).appex", bundleID: "com.test.app.e\($0)")
        }
        XCTAssertThrowsError(try ProvisioningIPAPreflight().inspect(archive(extensions: many)))
        XCTAssertEqual(try ProvisioningIPAPreflight().inspect(archive(extensions: Array(many.dropLast()))).extensions.count,
                       ProvisioningIPAPreflight.maximumExtensions)
    }

    // MARK: Identifiers

    func testExtensionsFollowASelectedSigningIdentifier() throws {
        XCTAssertEqual(try ProvisioningSigningIdentifier.extensionIdentifier("com.a.app.widget", originalApp: "com.a.app",
                                                                             targetApp: "com.b.app"), "com.b.app.widget")
        XCTAssertEqual(try ProvisioningSigningIdentifier.extensionIdentifier("com.a.app.widget", originalApp: "com.a.app",
                                                                             targetApp: "com.a.app"), "com.a.app.widget")
        for bad in ["com.a.appwidget", "com.a.app", "com.other.widget"] {
            XCTAssertThrowsError(try ProvisioningSigningIdentifier.extensionIdentifier(bad, originalApp: "com.a.app", targetApp: "com.b.app"))
        }
        let ipa = try archive(extensions: [.init(path: "PlugIns/Widget.appex", bundleID: "com.test.app.widget")])
        let request = ProvisioningRequest(accountID: UUID(), teamID: "TEAM12345", ipaURL: ipa, deviceUDID: "SYNTHETIC",
                                          signingBundleID: "com.personal.test")
        let app = try request.inspectedApp()
        XCTAssertEqual(app.bundleID, "com.personal.test")
        XCTAssertEqual(app.extensions.map(\.bundleID), ["com.personal.test.widget"])
    }

    // MARK: Developer Services

    func testCreatesOneAppIDAndProfilePerExtensionWithTheSameCertificateAndDevice() async throws {
        let gateway = try ExtensionGatewayFixture(cert: certificate(), created: [
            "bundle-com.test.app": profile("profile-valid"), "bundle-com.test.app.widget": profile("profile-extension")])
        let material = try await provisioner(gateway).provision(app: app(), deviceUDID: "SYNTHETIC-UDID", teamID: "TEAM12345",
                                                               confirmRevocation: { _ in false })
        XCTAssertEqual(material.profileData, try data("profile-valid", "mobileprovision"))
        XCTAssertEqual(material.extensions, [.init(bundleID: "com.test.app.widget",
            profileData: try data("profile-extension", "mobileprovision"), profileExpiry: fixtureProfileExpiry)])
        XCTAssertEqual(material.profileExpiry, fixtureProfileExpiry)
        let mutations = await gateway.mutations
        XCTAssertEqual(mutations, ["bundle:com.test.app", "bundle:com.test.app.widget",
                                   "profile:bundle-com.test.app:cert:device", "profile:bundle-com.test.app.widget:cert:device"])
    }

    func testReusesListedExtensionProfilesWithoutMutation() async throws {
        let gateway = try ExtensionGatewayFixture(cert: certificate(), created: [:])
        try await gateway.seed(bundle: "com.test.app", profile: profile("profile-valid"))
        try await gateway.seed(bundle: "com.test.app.widget", profile: profile("profile-extension"))
        let material = try await provisioner(gateway).provision(app: app(), deviceUDID: "SYNTHETIC-UDID", teamID: "TEAM12345",
                                                               confirmRevocation: { _ in false })
        XCTAssertEqual(material.extensions.map(\.bundleID), ["com.test.app.widget"])
        let mutations = await gateway.mutations
        XCTAssertEqual(mutations, [])
    }

    func testIncompatibleExtensionAppIDStopsBeforeAnyMutation() async throws {
        let gateway = try ExtensionGatewayFixture(cert: certificate(), created: [:])
        await gateway.seed(bundle: "com.test.app.widget", profile: nil, capabilities: ["PUSH_NOTIFICATIONS"])
        do {
            _ = try await provisioner(gateway).provision(app: app(), deviceUDID: "SYNTHETIC-UDID", teamID: "TEAM12345",
                                                        confirmRevocation: { _ in false })
            XCTFail("Incompatible extension App ID accepted")
        } catch ProvisioningError.unsupportedIPA(_) {}
        let mutations = await gateway.mutations
        XCTAssertEqual(mutations, [])
    }

    func testExtensionProfileForAnotherIdentifierIsNeverAccepted() async throws {
        // Apple returning the app's profile for the extension App ID must fail validation.
        let gateway = try ExtensionGatewayFixture(cert: certificate(), created: [
            "bundle-com.test.app": profile("profile-valid"), "bundle-com.test.app.widget": profile("profile-valid")])
        do {
            _ = try await provisioner(gateway).provision(app: app(), deviceUDID: "SYNTHETIC-UDID", teamID: "TEAM12345",
                                                        confirmRevocation: { _ in false })
            XCTFail("Mismatched extension profile accepted")
        } catch {}
        let mutations = await gateway.mutations
        XCTAssertEqual(mutations.filter { $0.hasPrefix("profile:bundle-com.test.app.widget") }.count, 1)
    }

    func testOlderMaterialWithoutExtensionFieldStillDecodes() throws {
        let legacy = Data(#"{"privateKeyPEM":"k","profileData":"AQ==","certificateExpiry":0,"profileExpiry":0}"#.utf8)
        let material = try JSONDecoder().decode(ProvisioningMaterial.self, from: legacy)
        XCTAssertNil(material.extensionProfiles)
        XCTAssertEqual(material.extensions, [])
    }

    // MARK: Helpers

    private struct ExtensionSpec {
        let path: String
        let bundleID: String
        var name: String = "Extension"
        var packageType: String = "XPC!"
        var executable: Data = ProvisioningIPAPreflightTests.macho()
    }

    private func archive(extensions: [ExtensionSpec]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let app = staging.appendingPathComponent("Payload/Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.test.app", "CFBundleExecutable": "Test",
                                   "CFBundleDisplayName": "Test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try ProvisioningIPAPreflightTests.macho().write(to: app.appendingPathComponent("Test"))
        for spec in extensions {
            let directory = app.appendingPathComponent(spec.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.deletingPathExtension().lastPathComponent
            let extensionInfo: [String: Any] = ["CFBundleIdentifier": spec.bundleID, "CFBundleExecutable": executable,
                                                "CFBundleDisplayName": spec.name, "CFBundlePackageType": spec.packageType]
            try PropertyListSerialization.data(fromPropertyList: extensionInfo, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("Info.plist"))
            try spec.executable.write(to: directory.appendingPathComponent(executable))
        }
        let ipa = root.appendingPathComponent("fixture.ipa")
        try FileManager.default.zipItem(at: staging, to: ipa, shouldKeepParent: false)
        return ipa
    }

    private func app() -> ProvisioningApp {
        ProvisioningApp(bundleID: "com.test.app", name: "Test",
                        extensions: [.init(bundleID: "com.test.app.widget", name: "Widget")])
    }
    private func certificate() throws -> DeveloperCertificate {
        DeveloperCertificate(id: "cert", serial: "69", name: "Synthetic", expiry: now.addingTimeInterval(86400),
                             der: try data("profile-dev", "cer"))
    }
    private func profile(_ name: String) throws -> DeveloperProfile {
        DeveloperProfile(id: name, content: try data(name, "mobileprovision"))
    }
    private func provisioner(_ gateway: ExtensionGatewayFixture) throws -> DeveloperServicesProvisioner {
        let pending = PendingSigningMaterial(privateKeyPEM: try data("test-key", "pem"), csr: "synthetic-csr",
                                             certificate: try certificate())
        let date = now
        return DeveloperServicesProvisioner(gateway: gateway, store: ExtensionStoreFixture(pending: pending),
            keys: ExtensionKeyFixture(pending: pending), anchors: [try data("profile-root", "cer")], now: { date })
    }
    private func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
}

private struct ExtensionKeyFixture: ProvisioningKeyGenerating {
    let pending: PendingSigningMaterial
    func generate() throws -> PendingSigningMaterial { pending }
}

private actor ExtensionStoreFixture: ProvisioningMaterialStoring {
    var pending: PendingSigningMaterial?
    init(pending: PendingSigningMaterial?) { self.pending = pending }
    func loadPending() async throws -> PendingSigningMaterial? { pending }
    func savePending(_ material: PendingSigningMaterial) async throws { pending = material }
    func invalidateCertificate(id: String) async throws {}
}

/// Keeps App IDs and profiles per identifier so several bundles can coexist.
private actor ExtensionGatewayFixture: DeveloperServicesGateway {
    let cert: DeveloperCertificate
    let created: [String: DeveloperProfile]
    var bundles: [String: DeveloperBundle] = [:]
    var listed: [String: [DeveloperProfile]] = [:]
    var mutations: [String] = []
    init(cert: DeveloperCertificate, created: [String: DeveloperProfile]) {
        self.cert = cert
        self.created = created
    }
    func seed(bundle identifier: String, profile: DeveloperProfile?, capabilities: [String] = []) {
        let bundle = DeveloperBundle(id: "bundle-" + identifier, identifier: identifier, capabilities: capabilities)
        bundles[identifier] = bundle
        if let profile { listed[bundle.id] = [profile] }
    }
    func listDevices() async throws -> [DeveloperDevice] { [.init(id: "device", udid: "SYNTHETIC-UDID", enabled: true)] }
    func registerDevice(udid: String) async throws -> DeveloperDevice { throw DeveloperServicesError.invalidResponse }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? { bundles[identifier] }
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle {
        mutations.append("bundle:" + identifier)
        let bundle = DeveloperBundle(id: "bundle-" + identifier, identifier: identifier, capabilities: [])
        bundles[identifier] = bundle
        return bundle
    }
    func listCertificates() async throws -> [DeveloperCertificate] { [cert] }
    func certificateDetails(id: String) async throws -> DeveloperCertificate { cert }
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate {
        mutations.append("certificate")
        throw DeveloperServicesError.invalidResponse
    }
    func revokeCertificate(id: String) async throws { mutations.append("revoke:" + id) }
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] { listed[bundleID] ?? [] }
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile {
        mutations.append("profile:\(bundleID):\(certificateID):\(deviceID)")
        guard let profile = created[bundleID] else { throw DeveloperServicesError.rejected(503) }
        return profile
    }
}
