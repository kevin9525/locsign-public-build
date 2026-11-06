import Foundation
import Security

struct PairingRecord {
    private let hostCertificateData: Data
    private let hostPrivateKeyData: Data
    private let rootCertificateData: Data

    let hostID: String
    let systemBUID: String

    init(data: Data) throws {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw LocSignError.install("配对文件不是 plist 字典") }

        guard let hostID = values["HostID"] as? String, !hostID.isEmpty,
              let systemBUID = values["SystemBUID"] as? String, !systemBUID.isEmpty
        else { throw LocSignError.install("配对文件缺少 HostID 或 SystemBUID") }

        guard let hostCertificateData = values["HostCertificate"] as? Data, !hostCertificateData.isEmpty,
              let hostPrivateKeyData = values["HostPrivateKey"] as? Data, !hostPrivateKeyData.isEmpty,
              let rootCertificateData = values["RootCertificate"] as? Data, !rootCertificateData.isEmpty else {
            throw LocSignError.install("配对文件缺少 TLS 证书或私钥")
        }

        self.hostCertificateData = hostCertificateData
        self.hostPrivateKeyData = hostPrivateKeyData
        self.rootCertificateData = rootCertificateData
        self.hostID = hostID
        self.systemBUID = systemBUID
    }

    func tlsIdentity() throws -> (identity: SecIdentity, certificateChain: [SecCertificate],
                                  trustRoots: [SecCertificate]) {
        guard let certificate = SecCertificateCreateWithData(nil, try Self.certificateDER(hostCertificateData) as CFData),
              let rootCertificate = SecCertificateCreateWithData(nil, try Self.certificateDER(rootCertificateData) as CFData) else {
            throw LocSignError.install("配对文件中的 TLS 证书无效")
        }

        guard let identity = LocSignCreateIdentity(certificate, hostPrivateKeyData) else {
            throw LocSignError.install("配对私钥无效或与证书不匹配")
        }
        return (identity, [rootCertificate], [rootCertificate])
    }

    private static func certificateDER(_ data: Data) throws -> Data {
        guard let pem = String(data: data, encoding: .utf8), pem.contains("-----BEGIN") else { return data }
        let lines = pem.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first == "-----BEGIN CERTIFICATE-----", lines.last == "-----END CERTIFICATE-----",
              let der = Data(base64Encoded: lines.dropFirst().dropLast().joined()), !der.isEmpty else {
            throw LocSignError.install("配对文件中的 PEM 证书无效")
        }
        return der
    }
}
