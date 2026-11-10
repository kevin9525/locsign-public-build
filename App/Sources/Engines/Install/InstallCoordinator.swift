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
        let lifetime = DeviceOperationLifetime()
        try await withTaskCancellationHandler {
            try await performInstall(ipaURL: ipaURL, host: host, pairingData: pairingData,
                                     lifetime: lifetime, progress: progress)
        } onCancel: {
            lifetime.close()
        }
    }

    private func performInstall(ipaURL: URL, host: String, pairingData: Data,
                                lifetime: DeviceOperationLifetime,
                                progress: @Sendable (Double) async -> Void) async throws {
        var stage = InstallationStep.readPackage
        var session: LockdownSession?
        var heartbeat: DeviceHeartbeat?
        var afcConnection: (any DeviceServiceTransport)?
        var installConnection: (any DeviceServiceTransport)?
        var afcClient: AFCClient?
        let remoteDirectory = "/PublicStaging/LocSign-\(UUID().uuidString)"
        let remotePath = "\(remoteDirectory)/app.ipa"

        do {
            try Task.checkCancellation()
            guard ipaURL.isFileURL, FileManager.default.fileExists(atPath: ipaURL.path) else {
                throw LocSignError.install("待安装 IPA 不存在")
            }
            let ipaSize = (try? ipaURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard ipaSize > 0 else { throw LocSignError.install("待安装 IPA 为空") }
            stage = .readPairing
            let pairing = try PairingRecord(data: pairingData)
            stage = .connectDevice
            let transport = lifetime.own(try await makeTransport(host))
            try Task.checkCancellation()
            let activeSession = LockdownSession(transport: transport, pairing: pairing)
            session = activeSession
            stage = .authenticate
            try await activeSession.start()
            stage = .readDevice
            _ = try await activeSession.queryUniqueDeviceID()
            stage = .startHeartbeat
            let heartbeatEndpoint = try await activeSession.startService("com.apple.mobile.heartbeat")
            stage = .connectHeartbeat
            let heartbeatConnection = lifetime.own(try await openService(host, heartbeatEndpoint, pairing))
            try Task.checkCancellation()
            let activeHeartbeat = DeviceHeartbeat(connection: heartbeatConnection)
            heartbeat = activeHeartbeat
            stage = .heartbeat
            try await activeHeartbeat.start()
            try activeHeartbeat.check()
            stage = .startAFC
            let afcEndpoint = try await activeSession.startService("com.apple.afc")
            stage = .startInstaller
            let installationEndpoint = try await activeSession.startService("com.apple.mobile.installation_proxy")
            stage = .connectAFC
            afcConnection = lifetime.own(try await openService(host, afcEndpoint, pairing))
            try Task.checkCancellation()
            stage = .connectInstaller
            installConnection = lifetime.own(try await openService(host, installationEndpoint, pairing))
            try Task.checkCancellation()

            guard let afcConnection, let installConnection else {
                throw LocSignError.install("安装服务连接未建立")
            }
            let afc = AFCClient(connection: afcConnection)
            afcClient = afc
            try activeHeartbeat.check()
            stage = .prepareUpload
            try await afc.makeDirectory(path: "/PublicStaging")
            try await afc.makeDirectory(path: remoteDirectory)
            stage = .upload
            try await afc.uploadFile(localURL: ipaURL, remotePath: remotePath) { value in
                await progress(min(0.35, value * 0.35))
            }
            await progress(0.35)
            try activeHeartbeat.check()
            let installer = InstallationProxyClient(connection: installConnection)
            stage = .sendInstall
            try await installer.install(packagePath: remotePath) { value in
                await progress(0.35 + min(max(value, 0), 1) * 0.65)
            }
            try Task.checkCancellation()
            await progress(1)
            if !Task.isCancelled {
                try? await afc.removePath(remotePath)
                try? await afc.removePath(remoteDirectory)
            }
            installConnection.close()
            afcConnection.close()
            await activeHeartbeat.stop()
            activeSession.close()
            lifetime.close()
            try Task.checkCancellation()
        } catch {
            let failure = InstallationFailure.wrapping(error, at: stage)
            if !Task.isCancelled, !(error is CancellationError), let afc = afcClient {
                try? await afc.removePath(remotePath)
                try? await afc.removePath(remoteDirectory)
            }
            installConnection?.close()
            afcConnection?.close()
            await heartbeat?.stop()
            session?.close()
            lifetime.close()
            throw failure
        }
    }
}
