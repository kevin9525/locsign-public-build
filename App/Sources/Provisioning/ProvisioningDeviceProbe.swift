import Foundation
import Network

protocol PairedDeviceProbing: Sendable {
    func deviceUDID(host: String, pairingData: Data) async throws -> String
}

struct ProvisioningDeviceProbe: PairedDeviceProbing {
    let connect: @Sendable (String) async throws -> any LockdownTransport
    init(connect: @escaping @Sendable (String) async throws -> any LockdownTransport = { try await LockdownNetworkTransport(host: $0) }) {
        self.connect = connect
    }
    func deviceUDID(host: String, pairingData: Data) async throws -> String {
        try Task.checkCancellation()
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else { throw LocSignError.install("请输入设备 IP 地址") }
        let pairing = try PairingRecord(data: pairingData)
        let transport = try await connect(address)
        let session = LockdownSession(transport: transport, pairing: pairing)
        defer { session.close() }
        try Task.checkCancellation()
        try await session.start()
        try Task.checkCancellation()
        let udid = try await session.queryUniqueDeviceID()
        try Task.checkCancellation()
        return udid
    }
}
