import XCTest
import Security
@testable import LocSign

final class ProvisioningKeyGeneratorTests: XCTestCase {
    func testGeneratesIndependentRSA2048KeysAndCSRForDurablePendingMaterial() throws {
        let first = try ProvisioningKeyGenerator().generate()
        let second = try ProvisioningKeyGenerator().generate()
        XCTAssertNotEqual(first.privateKeyPEM, second.privateKeyPEM)
        XCTAssertTrue(first.csr.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertTrue(first.csr.contains("-----END CERTIFICATE REQUEST-----"))
        XCTAssertNil(first.certificate)
        let pem = try XCTUnwrap(String(data: first.privateKeyPEM, encoding: .utf8))
        let payload = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: payload))
        let key = try XCTUnwrap(SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil))
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(key) as? [CFString: Any])
        XCTAssertEqual(attributes[kSecAttrKeySizeInBits] as? Int, 2048)
        let restored = try JSONDecoder().decode(PendingSigningMaterial.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restored.privateKeyPEM, first.privateKeyPEM)
        XCTAssertEqual(restored.csr, first.csr)
    }
}
