import XCTest
import Combine
@testable import LocSign

final class SigningLibraryCaptureTests: XCTestCase {
    private let oldExpiry = Date(timeIntervalSince1970: 1_800_003_600)
    private let newExpiry = Date(timeIntervalSince1970: 1_800_604_800)

    @MainActor
    func testSuccessfulInstallRetainsOriginalIPAAndConfirmedIdentityAcrossRelaunch() async throws {
        let fixture = try await setup()
        await fixture.installer.inspectBeforeUpload { [library = fixture.library] in
            let pending = try XCTUnwrap(library.apps.first)
            XCTAssertNotNil(pending.pending)
            XCTAssertNil(pending.installedAt)
            XCTAssertNil(pending.profileExpiry)
        }
        await install(fixture)
        XCTAssertTrue(fixture.model.installSucceeded)
        XCTAssertNil(fixture.model.error)

        let reopened = ManagedAppLibrary(directory: fixture.libraryDirectory)
        let saved = try XCTUnwrap(reopened.apps.first)
        XCTAssertEqual(saved.identity, fixture.identity)
        XCTAssertEqual(saved.profileExpiry, newExpiry)
        XCTAssertEqual(saved.certificateExpiry, Date(timeIntervalSince1970: 1_802_592_000))
        XCTAssertNotNil(saved.installedAt)
        XCTAssertNil(saved.pending)
        let retained = try reopened.sourceURL(for: saved.id)
        let imported = try XCTUnwrap(fixture.signer.inputURL)
        XCTAssertNotEqual(retained, imported)
        XCTAssertNotEqual(retained, fixture.signer.outputURL)
        try FileManager.default.removeItem(at: imported)
        fixture.model.discardOutput()
        XCTAssertEqual(try Data(contentsOf: retained), Data("original unsigned IPA".utf8))
        let uploaded = await fixture.installer.uploads
        XCTAssertEqual(uploaded, [Data("signed IPA sent to device".utf8)])
        XCTAssertNil(fixture.settings.operationID)
    }

    @MainActor
    func testFailedInstallPreservesPreviousExpiryAndSourceAcrossRelaunch() async throws {
        let fixture = try await setup(installFails: true, previouslyInstalled: true)
        let previous = try XCTUnwrap(fixture.library.apps.first)
        let previousSource = try fixture.library.sourceURL(for: previous.id)
        await fixture.installer.inspectBeforeUpload { [library = fixture.library] in
            let row = try XCTUnwrap(library.apps.first)
            XCTAssertEqual(row.profileExpiry, previous.profileExpiry)
            XCTAssertEqual(row.installedAt, previous.installedAt)
            XCTAssertNotNil(row.pending)
        }

        await install(fixture)
        XCTAssertFalse(fixture.model.installSucceeded)
        XCTAssertNotNil(fixture.model.error)
        let reopened = ManagedAppLibrary(directory: fixture.libraryDirectory)
        let saved = try XCTUnwrap(reopened.apps.first)
        XCTAssertEqual(saved.id, previous.id)
        XCTAssertEqual(saved.identity, previous.identity)
        XCTAssertEqual(saved.profileExpiry, previous.profileExpiry)
        XCTAssertEqual(saved.certificateExpiry, previous.certificateExpiry)
        XCTAssertEqual(saved.installedAt, previous.installedAt)
        XCTAssertNil(saved.pending)
        XCTAssertNotNil(saved.lastError)
        XCTAssertEqual(try reopened.sourceURL(for: saved.id), previousSource)
        XCTAssertEqual(try Data(contentsOf: previousSource), Data("previous retained original".utf8))
        let uploaded = await fixture.installer.uploads
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertNil(fixture.settings.operationID)
    }

    @MainActor
    func testChangingDeviceAfterSigningCannotCreateOrConfirmWrongDeviceRecord() async throws {
        let fixture = try await setup()
        await fixture.model.provisionAndSign(using: fixture.engine, account: fixture.account,
            teamID: "TEAM12345", providerAccepted: true)
        let output = try XCTUnwrap(fixture.model.outputURL)
        XCTAssertEqual(fixture.model.verifiedDeviceUDID, "ORIGINAL-DEVICE")
        XCTAssertTrue(fixture.library.apps.isEmpty)

        fixture.settings.updateHost("127.0.0.2")
        await fixture.probe.changeDevice(to: "DIFFERENT-DEVICE")
        // Changing the target preserves exported signed output, but installing
        // it must revalidate the identity used by the managed record.
        XCTAssertEqual(fixture.model.outputURL, output)
        await fixture.model.installSignedIPA()
        XCTAssertFalse(fixture.model.installSucceeded)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertTrue(fixture.library.apps.isEmpty)
        XCTAssertTrue(ManagedAppLibrary(directory: fixture.libraryDirectory).apps.isEmpty)
        let uploaded = await fixture.installer.uploads
        XCTAssertTrue(uploaded.isEmpty)
        XCTAssertNil(fixture.settings.operationID)
    }

    @MainActor
    func testCancellationAfterPendingCommitNeverUploadsOrStrandsExistingRecord() async throws {
        let fixture = try await setup(previouslyInstalled: true)
        let previous = try XCTUnwrap(fixture.library.apps.first)
        let previousSource = try fixture.library.sourceURL(for: previous.id)
        var task: Task<Void, Never>?
        var sawPending = false
        let observation = fixture.library.$apps.sink { rows in
            guard rows.contains(where: { $0.id == previous.id && $0.pending != nil }) else { return }
            // Published emits synchronously during the real manifest commit.
            // Cancellation is latched before prepare returns to the uploader.
            sawPending = true
            task?.cancel()
        }
        defer { observation.cancel() }
        task = Task { await install(fixture) }
        await task?.value

        XCTAssertTrue(sawPending)
        XCTAssertFalse(fixture.model.installSucceeded)
        let uploaded = await fixture.installer.uploads
        XCTAssertTrue(uploaded.isEmpty)
        let reopened = ManagedAppLibrary(directory: fixture.libraryDirectory)
        let saved = try XCTUnwrap(reopened.apps.first)
        XCTAssertEqual(saved.profileExpiry, previous.profileExpiry)
        XCTAssertEqual(saved.installedAt, previous.installedAt)
        XCTAssertEqual(try reopened.sourceURL(for: saved.id), previousSource)
        XCTAssertEqual(try Data(contentsOf: previousSource), Data("previous retained original".utf8))
        XCTAssertNil(saved.pending)
        XCTAssertNotNil(saved.lastError)
        XCTAssertNil(fixture.settings.operationID)
        XCTAssertFalse(fixture.model.busy)
    }

    @MainActor
    func testSelfInstallKeepsPreviousConfirmationAndRecoveryEvidence() async throws {
        let runningBundle = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let fixture = try await setup(previouslyInstalled: true, signingBundle: runningBundle)
        let previous = try XCTUnwrap(fixture.library.apps.first)
        let previousSource = try fixture.library.sourceURL(for: previous.id)

        await install(fixture)
        let uploaded = await fixture.installer.uploads
        XCTAssertEqual(uploaded.count, 1)
        let saved = try XCTUnwrap(ManagedAppLibrary(directory: fixture.libraryDirectory).apps.first)
        XCTAssertEqual(saved.profileExpiry, previous.profileExpiry)
        XCTAssertEqual(saved.installedAt, previous.installedAt)
        XCTAssertEqual(saved.pending?.profileExpiry, newExpiry)
        XCTAssertEqual(try fixture.library.sourceURL(for: saved.id), previousSource)
        XCTAssertNil(fixture.settings.operationID)
    }

    @MainActor
    private func install(_ fixture: Fixture) async {
        await fixture.model.installIPA(using: fixture.engine, account: fixture.account,
            teamID: "TEAM12345", canProvision: true)
    }

    @MainActor
    private struct Fixture {
        let model: SigningViewModel
        let settings: InstallationSettings
        let library: ManagedAppLibrary
        let libraryDirectory: URL
        let identity: ManagedApp.Identity
        let account: ProvisioningAccount
        let probe: CaptureProbeFixture
        let engine: CaptureEngineFixture
        let installer: CaptureInstallerFixture
        let signer: CaptureSignerFixture
    }

    @MainActor
    private func setup(installFails: Bool = false, previouslyInstalled: Bool = false,
                       signingBundle: String = "org.example.catalog.personal") async throws -> Fixture {
        let suite = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = InstallationSettings(directory: root.appendingPathComponent("Installation"), defaults: defaults)
        settings.updateHost("127.0.0.1")
        let pairingURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pairing-record-pem", withExtension: "plist"))
        try settings.savePairing(data: Data(contentsOf: pairingURL), name: "synthetic.plist")
        let libraryDirectory = root.appendingPathComponent("Library")
        let library = ManagedAppLibrary(directory: libraryDirectory,
            runningBundleID: Bundle.main.bundleIdentifier, currentProfile: Data("previous profile".utf8))
        let identity = ManagedApp.Identity(appleID: "user@example.com", teamID: "TEAM12345", deviceUDID: "ORIGINAL-DEVICE",
            originalBundleID: "org.example.catalog", signingBundleID: signingBundle)
        if previouslyInstalled {
            let previousSource = root.appendingPathComponent("previous.ipa")
            try Data("previous retained original".utf8).write(to: previousSource)
            let old = ProvisioningMaterial(privateKeyPEM: "synthetic-key", profileData: Data("previous profile".utf8),
                certificateExpiry: Date(timeIntervalSince1970: 1_802_000_000), profileExpiry: oldExpiry,
                signingBundleID: signingBundle)
            let id = try await library.prepare(source: previousSource, name: "Previous", identity: identity, material: old)
            try library.confirmInstallation(id: id, now: Date(timeIntervalSince1970: 1_800_000_000))
            try FileManager.default.removeItem(at: previousSource)
        }
        let material = ProvisioningMaterial(privateKeyPEM: "synthetic-key", profileData: Data("new profile".utf8),
            certificateExpiry: Date(timeIntervalSince1970: 1_802_592_000), profileExpiry: newExpiry,
            signingBundleID: signingBundle)
        let account = ProvisioningAccount(id: UUID(), appleID: "User@Example.com", teams: [.init(id: "TEAM12345", name: "Team")])
        let engine = CaptureEngineFixture(material: material)
        let probe = CaptureProbeFixture()
        let installer = CaptureInstallerFixture(fail: installFails)
        let signer = CaptureSignerFixture(outputURL: root.appendingPathComponent("signed.ipa"))
        let model = SigningViewModel(settings: settings, library: library, installer: installer, deviceProbe: probe,
            inspectBundleID: { _ in "org.example.catalog" }, materialSigner: signer.sign)
        let source = root.appendingPathComponent("original.ipa")
        try Data("original unsigned IPA".utf8).write(to: source)
        await model.importFile(source, as: .ipa)
        try FileManager.default.removeItem(at: source)
        model.usesPersonalBundleID = true
        model.personalBundleID = signingBundle
        return Fixture(model: model, settings: settings, library: library, libraryDirectory: libraryDirectory,
            identity: identity, account: account, probe: probe, engine: engine, installer: installer, signer: signer)
    }
}

@MainActor
private final class CaptureSignerFixture {
    let outputURL: URL
    private(set) var inputURL: URL?
    init(outputURL: URL) { self.outputURL = outputURL }
    func sign(_ input: URL, _ material: ProvisioningMaterial) async throws -> URL {
        inputURL = input
        XCTAssertEqual(try Data(contentsOf: input), Data("original unsigned IPA".utf8))
        try Data("signed IPA sent to device".utf8).write(to: outputURL)
        return outputURL
    }
}

private actor CaptureProbeFixture: PairedDeviceProbing {
    private var device = "ORIGINAL-DEVICE"
    func changeDevice(to value: String) { device = value }
    func deviceUDID(host: String, pairingData: Data) async throws -> String {
        _ = try PairingRecord(data: pairingData)
        return device
    }
}

private actor CaptureEngineFixture: ProvisioningEngine {
    let material: ProvisioningMaterial
    init(material: ProvisioningMaterial) { self.material = material }
    func logIn(appleID: String, password: String, twoFactorCode: @escaping TwoFactorCodeProvider) async throws -> ProvisioningAccount {
        throw ProvisioningError.invalidAccount
    }
    func restoreAccount() async throws -> ProvisioningAccount? { nil }
    func logout(account: String) async throws {}
    func cancel() async {}
    func cachedMaterial(request: ProvisioningRequest) async throws -> ProvisioningMaterial? { material }
    func provision(request: ProvisioningRequest, confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool) async throws -> ProvisioningMaterial {
        material
    }
}

private actor CaptureInstallerFixture: IPAInstalling {
    let fail: Bool
    private var inspection: (@MainActor () throws -> Void)?
    private(set) var uploads: [Data] = []
    init(fail: Bool) { self.fail = fail }
    func inspectBeforeUpload(_ inspection: @escaping @MainActor () throws -> Void) { self.inspection = inspection }
    func install(ipaURL: URL, host: String, pairingData: Data, progress: @Sendable (Double) async -> Void) async throws {
        try await inspection?()
        uploads.append(try Data(contentsOf: ipaURL))
        _ = try PairingRecord(data: pairingData)
        await progress(1)
        if fail { throw LocSignError.install("Synthetic installation did not complete") }
    }
}
