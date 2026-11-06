import Foundation

protocol PairedDeviceProbing: Sendable {
    func deviceUDID(host: String, pairingData: Data) async throws -> String
}

struct ProvisioningDeviceProbe: PairedDeviceProbing {
    let connect: @Sendable (String) async throws -> any LockdownTransport
    init(connect: @escaping @Sendable (String) async throws -> any LockdownTransport = { try await LockdownNetworkTransport(host: $0) }) {
        self.connect = connect
    }
    func deviceUDID(host: String, pairingData: Data) async throws -> String {
        throw ProvisioningError.materialInvalid("设备尚未验证")
    }
}
