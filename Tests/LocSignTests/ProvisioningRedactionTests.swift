import XCTest
@testable import LocSign

final class ProvisioningRedactionTests: XCTestCase {
    func testRemovesAuthenticationKeysAndAppleIDFromMessages() {
        for value in ["password=synthetic-password", "X-Apple-GS-Token: synthetic-token",
                      "adi_pb=synthetic-adi", "X-Apple-I-MD: synthetic-otp", "HostPrivateKey=synthetic-pairing-key",
                      "account=user@example.com", "-----BEGIN RSA PRIVATE KEY-----\nsynthetic-private-key\n-----END RSA PRIVATE KEY-----"] {
            let redacted = ProvisioningRedaction.redact(value)
            XCTAssertFalse(redacted.contains("synthetic-"))
            XCTAssertFalse(redacted.contains("user@example.com"))
        }
    }
    func testPreservesPublicProgressAndSafeFailureMessages() {
        XCTAssertEqual(ProvisioningRedaction.redact("材料已验证，等待签名"), "材料已验证，等待签名")
        XCTAssertEqual(ProvisioningRedaction.redact("Apple 服务连接失败（503）"), "Apple 服务连接失败（503）")
        XCTAssertEqual(ProvisioningRedaction.redact("Anisette 数据不可用，请检查提供方或重新登录"), "Anisette 数据不可用，请检查提供方或重新登录")
    }
}
