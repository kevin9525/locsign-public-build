import XCTest
@testable import LocSign

final class AnisetteProviderTests: XCTestCase {
    func testRequiresSecureProviderURLWithoutCredentialsQueryOrFragment() throws {
        for value in ["http://example.com", "ws://example.com", "file:///tmp/provider",
                      "https://user:secret@example.com", "https://example.com?token=secret",
                      "https://example.com/#fragment"] {
            XCTAssertThrowsError(try AnisetteProviderConfiguration(endpoint: XCTUnwrap(URL(string: value))), value)
        }
    }

    func testCanonicalProviderIdentityAndPrivacyDisclosure() throws {
        let a = try configuration("https://EXAMPLE.com:443/")
        let b = try configuration("https://example.com")
        let c = try configuration("https://different.example.com")
        XCTAssertEqual(a.providerID, b.providerID)
        XCTAssertNotEqual(a.providerID, c.providerID)
        XCTAssertTrue(a.providerID.hasPrefix("omnisette-v3:"))
        for text in ["https://example.com", "UUID", "ADI", "IP"] {
            XCTAssertTrue(a.privacySummary.contains(text))
        }
    }

    func testRejectsAppleCredentialsAtProviderBoundary() throws {
        let boundary = ProvisioningNetworkBoundary.provider(try configuration())
        for header in ["Authorization", "Cookie", "X-Apple-GS-Token", "X-Apple-Identity-Token",
                       "X-MMe-Device-Id", "X-Apple-I-MD", "X-Apple-I-MD-M", "X-MMe-Client-Info"] {
            var request = request("https://example.com/v3/get_headers")
            request.setValue("synthetic-sensitive-value", forHTTPHeaderField: header)
            XCTAssertThrowsError(try boundary.validate(request), header)
        }
        var allowed = request("https://example.com/v3/get_headers")
        allowed.setValue("application/json", forHTTPHeaderField: "Content-Type")
        XCTAssertNoThrow(try boundary.validate(allowed))
    }

    func testProviderCannotRequestAppleOrDifferentProvider() throws {
        let boundary = ProvisioningNetworkBoundary.provider(try configuration())
        for url in ["https://gsa.apple.com/v3/get_headers", "https://other.example.com/v3/get_headers",
                    "http://example.com/v3/get_headers", "https://example.com:444/v3/get_headers"] {
            XCTAssertThrowsError(try boundary.validate(request(url)), url)
        }
        XCTAssertNoThrow(try boundary.validate(request("wss://example.com/v3/provisioning_session"), webSocket: true))
        XCTAssertThrowsError(try boundary.validate(request("ws://example.com/v3/provisioning_session"), webSocket: true))
    }

    func testAppleBoundaryRejectsProviderAndLookalikeHosts() throws {
        for value in ["https://example.com", "http://gsa.apple.com", "https://gsa.apple.com.attacker.test",
                      "https://user@evil.test", "https://gsa.apple.com:444"] {
            XCTAssertThrowsError(try ProvisioningNetworkBoundary.apple.validate(request(value)), value)
        }
        XCTAssertNoThrow(try ProvisioningNetworkBoundary.apple.validate(request("https://gsa.apple.com/grandslam/GsService2")))
        XCTAssertNoThrow(try ProvisioningNetworkBoundary.apple.validate(request("https://developerservices2.apple.com/services")))
    }

    func testRejectsRedirectAcrossOriginOrToInsecureScheme() throws {
        let boundary = ProvisioningNetworkBoundary.apple
        let original = request("https://gsa.apple.com/start")
        XCTAssertFalse(boundary.permitsRedirect(from: original, to: request("https://example.com/stolen")))
        XCTAssertFalse(boundary.permitsRedirect(from: original, to: request("https://developerservices2.apple.com/stolen")))
        XCTAssertFalse(boundary.permitsRedirect(from: original, to: request("http://gsa.apple.com/stolen")))
        XCTAssertTrue(boundary.permitsRedirect(from: original, to: request("https://gsa.apple.com/next")))
    }

    func testAccountSessionUsesNoDiskCacheCookiesOrCredentialStorage() {
        let config = DirectURLSession.configuration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    private func request(_ value: String) -> URLRequest { URLRequest(url: URL(string: value)!) }
    private func configuration(_ value: String = "https://example.com") throws -> AnisetteProviderConfiguration {
        try AnisetteProviderConfiguration(endpoint: XCTUnwrap(URL(string: value)))
    }
}
