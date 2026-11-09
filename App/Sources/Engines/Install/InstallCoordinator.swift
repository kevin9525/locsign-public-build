import Foundation

protocol IPAInstalling {
    func install(ipaURL: URL, host: String, pairingData: Data,
                 progress: @Sendable (Double) async -> Void) async throws
}

final class InstallCoordinator: IPAInstalling {
    private let makeTransport: (String) async throws -> any LockdownTransport
    private let openService: (String, LockdownServiceEndpoint, PairingRecord) async throws -> any DeviceServiceTransport

    init(makeTransport: @escaping (String) async throws -> any LockdownTransport = {
        try await LockdownNetworkTransport(host: $0)
    }, openService: @escaping (String, LockdownServiceEndpoint, PairingRecord) async throws -> any DeviceServiceTransport = {
        try await DeviceServiceConnection(host: $0, endpoint: $1, pairing: $2)
    }) {
        self.makeTransport = makeTransport
        self.openService = openService
    }

    func install(ipaURL: URL, host: String, pairingData: Data,
                 progress: @Sendable (Double) async -> Void = { _ in }) async throws {
        var stage = InstallationStep.readPackage
        var session: LockdownSession?
        var afcConnection: (any DeviceServiceTransport)?
        var installConnection: (any DeviceServiceTransport)?
        var afcClient: AFCClient?
        let remoteDirectory = "/PublicStaging/LocSign-\(UUID().uuidString)"
        let remotePath = "\(remoteDirectory)/app.ipa"

        do {
            guard ipaURL.isFileURL, FileManager.default.fileExists(atPath: ipaURL.path) else {
                throw LocSignError.install("待安装 IPA 不存在")
            }
            let ipaSize = (try? ipaURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard ipaSize > 0 else { throw LocSignError.install("待安装 IPA 为空") }
            stage = .readPairing
            let pairing = try PairingRecord(data: pairingData)
            stage = .connectDevice
            let transport = try await makeTransport(host)
            let activeSession = LockdownSession(transport: transport, pairing: pairing)
            session = activeSession
            stage = .authenticate
            try await activeSession.start()
            stage = .readDevice
            _ = try await activeSession.queryUniqueDeviceID()
            stage = .startAFC
            let afcEndpoint = try await activeSession.startService("com.apple.afc")
            stage = .startInstaller
            let installationEndpoint = try await activeSession.startService("com.apple.mobile.installation_proxy")
            stage = .connectAFC
            afcConnection = try await openService(host, afcEndpoint, pairing)
            stage = .connectInstaller
            installConnection = try await openService(host, installationEndpoint, pairing)

            guard let afcConnection, let installConnection else {
                throw LocSignError.install("安装服务连接未建立")
            }
            let afc = AFCClient(connection: afcConnection)
            afcClient = afc
            stage = .prepareUpload
            try await afc.makeDirectory(path: "/PublicStaging")
            try await afc.makeDirectory(path: remoteDirectory)
            stage = .upload
            try await afc.uploadFile(localURL: ipaURL, remotePath: remotePath) { value in
                await progress(min(0.35, value * 0.35))
            }
            await progress(0.35)
            let installer = InstallationProxyClient(connection: installConnection)
            stage = .sendInstall
            try await installer.install(packagePath: remotePath) { value in
                await progress(0.35 + min(max(value, 0), 1) * 0.65)
            }
            await progress(1)
            try? await afc.removePath(remotePath)
            try? await afc.removePath(remoteDirectory)
            installConnection.close()
            afcConnection.close()
            activeSession.close()
        } catch {
            let failure = InstallationFailure.wrapping(error, at: stage)
            if let afc = afcClient {
                try? await afc.removePath(remotePath)
                try? await afc.removePath(remoteDirectory)
            }
            installConnection?.close()
            afcConnection?.close()
            session?.close()
            throw failure
        }
    }
}
