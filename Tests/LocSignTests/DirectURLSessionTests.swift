import XCTest
@testable import LocSign

final class DirectURLSessionTests: XCTestCase {
    func testProxyDictionaryIsEmpty() throws {
        let config = DirectURLSession.configuration()
        // 空字典（非 nil）是关键：显式声明"无代理"覆盖系统配置——M0 实测代理 IP 触发 Apple 风控
        XCTAssertNotNil(config.connectionProxyDictionary)
        XCTAssertTrue(config.connectionProxyDictionary!.isEmpty,
                      "connectionProxyDictionary 必须为空字典以绕过系统代理")
    }
    func testSessionCreated() {
        let session = DirectURLSession.make()
        let dict = session.configuration.connectionProxyDictionary ?? [:]
        XCTAssertTrue(dict.isEmpty, "会话配置必须绕过系统代理")
    }
}
