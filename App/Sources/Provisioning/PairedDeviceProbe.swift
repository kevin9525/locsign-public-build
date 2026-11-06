import Foundation

protocol PairedDeviceProbing: Sendable {
    func deviceUDID(host: String, pairingData: Data) async throws -> String
}

struct PairedDeviceProbe: PairedDeviceProbing {
    func deviceUDID(host: String, pairingData: Data) async throws -> String {
        throw ProvisioningError.materialInvalid("设备尚未验证")
    }
}
