import Foundation
import Security

/// Converts the saved installation pairing record for the pinned native parser.
/// The source stays untouched; the device leaf must come from authenticated TLS.
enum LocationPairingRecord {
    static func prepare(_ data: Data, authenticatedDeviceCertificate peerDER: Data) throws -> Data {
        let pairing = try PairingRecord(data: data)
        let materials = try pairing.tlsIdentity()
        guard let peer = SecCertificateCreateWithData(nil, peerDER as CFData) else {
            throw LocationControlError.message("缺少已验证的设备证书，请重新连接设备")
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(peer, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { throw LocationControlError.message("无法校验定位连接的设备证书") }
        var trustError: NSError?
        guard LocSignVerifyPairingTrust(trust, materials.trustRoots, &trustError) else {
            throw LocationControlError.message("定位连接的设备证书未通过原配对信任校验")
        }
        guard let source = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LocationControlError.message("配对文件不是 plist 字典")
        }
        if let previous = source["DeviceCertificate"] {
            guard let previous = previous as? Data, try certificateDER(previous) == peerDER else {
                throw LocationControlError.message("配对文件与当前连接的设备证书不一致，请检查是否选择了同一台设备的配对文件")
            }
        }
        var hostCertificate: SecCertificate?
        var hostKey: SecKey?
        guard SecIdentityCopyCertificate(materials.identity, &hostCertificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(materials.identity, &hostKey) == errSecSuccess,
              let hostCertificate, let hostKey, let root = materials.trustRoots.first,
              let keyDER = SecKeyCopyExternalRepresentation(hostKey, nil) as Data? else {
            throw LocationControlError.message("无法读取已验证的配对身份")
        }
        let attributes = SecKeyCopyAttributes(hostKey) as? [String: Any]
        guard attributes?[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String else {
            throw LocationControlError.message("定位模块暂不支持此配对私钥类型")
        }
        var native: [String: Any] = [
            "HostID": pairing.hostID, "SystemBUID": pairing.systemBUID,
            "HostCertificate": pem(SecCertificateCopyData(hostCertificate) as Data, label: "CERTIFICATE"),
            "HostPrivateKey": pem(keyDER, label: "RSA PRIVATE KEY"),
            "RootCertificate": pem(SecCertificateCopyData(root) as Data, label: "CERTIFICATE"),
            "DeviceCertificate": pem(peerDER, label: "CERTIFICATE"),
            // Required by upstream's schema, unused by its ring/TCP session path.
            // Never copy or synthesize a root signing key.
            "RootPrivateKey": Data(),
            "WiFiMACAddress": source["WiFiMACAddress"] as? String ?? ""
        ]
        if let escrow = source["EscrowBag"] as? Data { native["EscrowBag"] = escrow }
        if let udid = source["UDID"] as? String { native["UDID"] = udid }
        return try PropertyListSerialization.data(fromPropertyList: native, format: .xml, options: 0)
    }

    private static func certificateDER(_ data: Data) throws -> Data {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard lines.first == "-----BEGIN CERTIFICATE-----", lines.last == "-----END CERTIFICATE-----",
                  let der = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else {
                throw LocationControlError.message("配对文件中的设备证书格式无效")
            }
            return der
        }
        return data
    }
    private static func pem(_ data: Data, label: String) -> Data {
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n".utf8)
    }
}
