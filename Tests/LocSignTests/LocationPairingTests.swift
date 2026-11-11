import XCTest
import Security
@testable import LocSign

final class LocationPairingTests: XCTestCase {
    func testExistingMinimalPairingReproducesNativeCode13BeforeAdaptation() throws {
        let original = try fixture("pairing-record-pem", "plist")
        _ = try PairingRecord(data: original).tlsIdentity()
        XCTAssertThrowsError(try LSDeviceLocationSession.validatePairingData(original)) { error in
            XCTAssertEqual((error as NSError).code, 13)
        }
    }

    func testMinimalPEMPairingIsAcceptedByNativeParserWithoutChangingIdentity() throws {
        let original = try fixture("pairing-record-pem", "plist")
        let peer = try fixture("pairing-host-cert", "der")
        let prepared = try LocationPairingRecord.prepare(original, authenticatedDeviceCertificate: peer)
        try LSDeviceLocationSession.validatePairingData(prepared)
        let before = try PairingRecord(data: original)
        let after = try PairingRecord(data: prepared)
        XCTAssertEqual(after.hostID, before.hostID)
        XCTAssertEqual(after.systemBUID, before.systemBUID)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(try after.tlsIdentity().identity, &certificate), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(certificate)) as Data, peer)
        let values = try dictionary(prepared)
        XCTAssertEqual(values["RootPrivateKey"] as? Data, Data())
        XCTAssertEqual(values["WiFiMACAddress"] as? String, "")
        XCTAssertNil(try dictionary(original)["DeviceCertificate"], "The imported file must remain unchanged")
    }

    func testBinaryPlistAndDERIdentityAlsoWorkWithNativeParser() throws {
        let values = try dictionary(fixture("pairing-record", "plist"))
        let binary = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let prepared = try LocationPairingRecord.prepare(binary,
            authenticatedDeviceCertificate: fixture("pairing-host-cert", "der"))
        try LSDeviceLocationSession.validatePairingData(prepared)
        _ = try PairingRecord(data: prepared).tlsIdentity()
    }

    func testPreparedDevicePinIsDistinctFromHostCertificate() throws {
        let original = try fixture("pairing-record-pem", "plist")
        let device = try fixture("pairing-location-device", "der")
        let host = try fixture("pairing-host-cert", "der")
        XCTAssertNotEqual(host, device)
        let prepared = try LocationPairingRecord.prepare(original, authenticatedDeviceCertificate: device)
        try LSDeviceLocationSession.validatePairingData(prepared)
        let values = try dictionary(prepared)
        func der(_ field: String) throws -> Data {
            let bytes = try XCTUnwrap(values[field] as? Data)
            let pem = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            let payload = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
            return try XCTUnwrap(Data(base64Encoded: payload))
        }
        XCTAssertEqual(try der("DeviceCertificate"), device)
        XCTAssertEqual(try der("HostCertificate"), host)
    }

    func testFullRecordPreservesEscrowButDoesNotPassRootSigningKeyToNativeLibrary() throws {
        var values = try dictionary(fixture("pairing-record-pem", "plist"))
        let peer = try fixture("pairing-host-cert", "der")
        values["DeviceCertificate"] = peer
        values["RootPrivateKey"] = Data("unused root signing secret".utf8)
        values["WiFiMACAddress"] = "02:00:00:00:00:01"
        values["EscrowBag"] = Data([4, 5, 6])
        let original = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let prepared = try LocationPairingRecord.prepare(original, authenticatedDeviceCertificate: peer)
        try LSDeviceLocationSession.validatePairingData(prepared)
        let result = try dictionary(prepared)
        XCTAssertEqual(result["RootPrivateKey"] as? Data, Data())
        XCTAssertEqual(result["EscrowBag"] as? Data, Data([4, 5, 6]))
        XCTAssertEqual(result["WiFiMACAddress"] as? String, "02:00:00:00:00:01")
    }

    func testRejectsPeerOutsideTheImportedPairingRoot() throws {
        XCTAssertThrowsError(try LocationPairingRecord.prepare(fixture("pairing-record-pem", "plist"),
            authenticatedDeviceCertificate: fixture("pairing-legacy-device", "der")))
    }

    func testAcceptsLegacyAppleDeviceLeafButRejectsExpiredOrTamperedLeaf() throws {
        var values = try dictionary(fixture("pairing-record-pem", "plist"))
        values["RootCertificate"] = try fixture("pairing-legacy-root", "der")
        let original = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let prepared = try LocationPairingRecord.prepare(original,
            authenticatedDeviceCertificate: fixture("pairing-legacy-device", "der"))
        try LSDeviceLocationSession.validatePairingData(prepared)
        for name in ["pairing-legacy-expired", "pairing-legacy-bad-signature"] {
            XCTAssertThrowsError(try LocationPairingRecord.prepare(original,
                authenticatedDeviceCertificate: fixture(name, "der")))
        }
    }

    func testRejectsConflictingDeviceCertificateInFullPairing() throws {
        var values = try dictionary(fixture("pairing-record-pem", "plist"))
        values["DeviceCertificate"] = try fixture("pairing-legacy-device", "der")
        let original = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        XCTAssertThrowsError(try LocationPairingRecord.prepare(original,
            authenticatedDeviceCertificate: fixture("pairing-host-cert", "der"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("设备证书不一致"))
        }
    }

    func testRejectsMissingPeerAndInvalidHostKey() throws {
        let original = try fixture("pairing-record-pem", "plist")
        XCTAssertThrowsError(try LocationPairingRecord.prepare(original, authenticatedDeviceCertificate: Data()))
        var values = try dictionary(original)
        values["HostPrivateKey"] = Data([1, 2, 3])
        let invalid = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        XCTAssertThrowsError(try LocationPairingRecord.prepare(invalid,
            authenticatedDeviceCertificate: fixture("pairing-host-cert", "der")))
    }

    func testNativeParseFailureDoesNotTellUserToChangeVPN() {
        XCTAssertThrowsError(try LSDeviceLocationSession.validatePairingData(Data("not a plist".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("配对文件"))
            XCTAssertFalse(error.localizedDescription.contains("LocalDevVPN"))
        }
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }
    private func dictionary(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
