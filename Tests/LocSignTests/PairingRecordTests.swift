import XCTest
import Security
import CoreFoundation
@testable import LocSign

final class PairingRecordTests: XCTestCase {
    func testParsesRequiredPairingMetadata() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "HostID": "host-1",
            "SystemBUID": "buid-1",
            "HostCertificate": Data([1]),
            "HostPrivateKey": Data([2]),
            "RootCertificate": Data([3])
        ], format: .binary, options: 0)

        let record = try PairingRecord(data: data)
        XCTAssertEqual(record.hostID, "host-1")
        XCTAssertEqual(record.systemBUID, "buid-1")
    }

    func testRejectsPairingRecordWithoutPrivateKey() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "HostID": "host-1",
            "SystemBUID": "buid-1",
            "HostCertificate": Data([1]),
            "RootCertificate": Data([3])
        ], format: .binary, options: 0)

        XCTAssertThrowsError(try PairingRecord(data: data))
    }

    func testRejectsMalformedTLSMaterialBeforeNetworkUse() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "HostID": "host-1", "SystemBUID": "buid-1",
            "HostCertificate": Data([1]), "HostPrivateKey": Data([2]),
            "RootCertificate": Data([3])
        ], format: .binary, options: 0)
        let record = try PairingRecord(data: data)
        XCTAssertThrowsError(try record.tlsIdentity())
    }

    func testBuildsTLSIdentityFromPairingCertificateAndPrivateKey() throws {
        let url = try XCTUnwrap(Bundle(for: PairingRecordTests.self)
            .url(forResource: "pairing-record", withExtension: "plist"))
        let record = try PairingRecord(data: Data(contentsOf: url))

        let (identity, chain, roots) = try record.tlsIdentity()
        XCTAssertEqual(CFGetTypeID(identity), SecIdentityGetTypeID())
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(chain.count, 1)
    }

    func testBuildsIdentityFromPEMCertificatesAndPKCS8Key() throws {
        let url = try XCTUnwrap(Bundle(for: PairingRecordTests.self)
            .url(forResource: "pairing-record-pem", withExtension: "plist"))
        let record = try PairingRecord(data: Data(contentsOf: url))
        let materials = try record.tlsIdentity()
        var privateKey: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(materials.identity, &privateKey), errSecSuccess)
        let key = try XCTUnwrap(privateKey)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(materials.identity, &certificate), errSecSuccess)
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(XCTUnwrap(certificate)))
        let message = Data("pairing proof".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                          message as CFData, nil))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                            message as CFData, signature, nil))
    }

    func testRejectsMismatchedPairingKey() throws {
        let url = try XCTUnwrap(Bundle(for: PairingRecordTests.self)
            .url(forResource: "pairing-record-pem", withExtension: "plist"))
        var values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                                  as? [String: Any])
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let otherKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        values["HostPrivateKey"] = try XCTUnwrap(SecKeyCopyExternalRepresentation(otherKey, nil)) as Data
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        XCTAssertThrowsError(try PairingRecord(data: data).tlsIdentity())
    }
}
