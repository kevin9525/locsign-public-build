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
        guard ipaURL.isFileURL, FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw LocSignError.install("待安装 IPA 不存在")
        }
        let ipaSize = (try? ipaURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard ipaSize > 0 else {
            throw LocSignError.install("待安装 IPA 为空")
        }
        let pairing = try PairingRecord(data: pairingData)
        let transport = try await makeTransport(host)
        let session = LockdownSession(transport: transport, pairing: pairing)
        var afcConnection: (any DeviceServiceTransport)?
        var installConnection: (any DeviceServiceTransport)?
        var afcClient: AFCClient?
        let remoteDirectory = "/PublicStaging/LocSign-\(UUID().uuidString)"
        let remotePath = "\(remoteDirectory)/app.ipa"

        do {
            try await session.start()
            _ = try await session.queryUniqueDeviceID()
            let afcEndpoint = try await session.startService("com.apple.afc")
            let installationEndpoint = try await session.startService("com.apple.mobile.installation_proxy")
            afcConnection = try await openService(host, afcEndpoint, pairing)
            installConnection = try await openService(host, installationEndpoint, pairing)

            guard let afcConnection, let installConnection else {
                throw LocSignError.install("安装服务连接未建立")
            }
            let afc = AFCClient(connection: afcConnection)
            afcClient = afc
            try await afc.makeDirectory(path: "/PublicStaging")
            try await afc.makeDirectory(path: remoteDirectory)
            try await afc.uploadFile(localURL: ipaURL, remotePath: remotePath) { value in
                await progress(min(0.35, value * 0.35))
            }
            await progress(0.35)
            let installer = InstallationProxyClient(connection: installConnection)
            try await installer.install(packagePath: remotePath) { value in
                await progress(0.35 + min(max(value, 0), 1) * 0.65)
            }
            await progress(1)
            try? await afc.removePath(remotePath)
            try? await afc.removePath(remoteDirectory)
            installConnection.close()
            afcConnection.close()
            session.close()
        } catch {
            if let afc = afcClient {
                try? await afc.removePath(remotePath)
                try? await afc.removePath(remoteDirectory)
            }
            installConnection?.close()
            afcConnection?.close()
            session.close()
            throw error
        }
    }
}
