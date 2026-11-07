import XCTest
@testable import LocSign

final class DeveloperServicesErrorTests: XCTestCase {
    func testDeveloperServicesFailuresExposeActionableDescriptions() {
        XCTAssertEqual(
            DeveloperServicesError.rejected(409).localizedDescription,
            "Apple Developer Services 请求被拒绝（HTTP 409）"
        )
        XCTAssertEqual(
            DeveloperServicesError.invalidResponse.localizedDescription,
            "Apple Developer Services 返回的数据无效，无法继续申请材料"
        )
        XCTAssertEqual(
            DeveloperServicesError.certificateQuota.localizedDescription,
            "Apple 开发者服务拒绝申请：开发证书数量已达上限"
        )
        XCTAssertEqual(
            DeveloperServicesError.remoteChanged.localizedDescription,
            "Apple Developer Services 证书列表发生变化，请重新申请"
        )
    }
}
