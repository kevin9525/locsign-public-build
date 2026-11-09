import Foundation

final class InstallationProxyClient {
    private let connection: any DeviceServiceTransport

    init(connection: any DeviceServiceTransport) { self.connection = connection }

    func install(packagePath: String, progress: @Sendable (Double) async -> Void) async throws {
        try await connection.sendPlist(InstallationProxyProtocol.installRequest(packagePath: packagePath))
        while true {
            try Task.checkCancellation()
            let response = try await connection.receivePlist()
            let update = try InstallationProxyProtocol.progress(from: response)
            if let value = update.percent { await progress(value / 100.0) }
            if update.complete { break }
        }
    }
}
