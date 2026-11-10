import XCTest
import XKit
import OpenAPIRuntime
@testable import LocSign

final class AnisetteTransportTests: XCTestCase {
    func testLiveAdapterClassifiesProfileConflictBeforeDiscardingSensitiveBody() async throws {
        let client = XKitHTTPClientAdapter(boundary: .apple, protocolClasses: [ProfileConflictURLProtocol.self])
        do {
            _ = try await client.makeRequest(XKit.HTTPRequest(method: .post,
                url: URL(string: "https://developerservices2.apple.com/services/v1/profiles")!))
            XCTFail("Profile conflict accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已有描述文件"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 409"))
            XCTAssertFalse(String(describing: error).contains("synthetic-server-secret"))
        }
    }

    func testUnrecognizedAppleConflictKeepsStatusAndDiscardsBody() async throws {
        let client = XKitHTTPClientAdapter(boundary: .apple, protocolClasses: [RegistrationConflictURLProtocol.self])
        let result = try await client.makeRequest(XKit.HTTPRequest(url: URL(string: "https://developerservices2.apple.com/services/v1/unknown")!), requireHTTPSuccess: false)
        XCTAssertEqual(result.response.status.code, 409)
        XCTAssertTrue(result.body.isEmpty)
    }

    func testRegistrationClassificationDoesNotChangeAuthenticationResponseHandling() async throws {
        let client = XKitHTTPClientAdapter(boundary: .apple, protocolClasses: [RegistrationConflictURLProtocol.self])
        let result = try await client.makeRequest(XKit.HTTPRequest(url: URL(string: "https://gsa.apple.com/auth")!), requireHTTPSuccess: false)
        XCTAssertEqual(result.response.status.code, 409)
        XCTAssertTrue(result.body.isEmpty)
    }

    func testAppleRegistrationRejectionKeepsOnlySafeClassification() async throws {
        let client = XKitHTTPClientAdapter(boundary: .apple, protocolClasses: [RegistrationConflictURLProtocol.self])
        do {
            _ = try await client.makeRequest(XKit.HTTPRequest(url: URL(string: "https://developerservices2.apple.com/services/v1/bundleIds")!))
            XCTFail("Known registration rejection should expose its safe classification")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("应用标识不可用"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 409"), error.localizedDescription)
            XCTAssertFalse(String(describing: error).contains("synthetic-server-secret"))
        }
    }

    func testOpenAPIRelativeRequestUsesValidatedBaseURLAndPreservesBasePath() async throws {
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let client = XKitHTTPClientAdapter(boundary: .provider(config), protocolClasses: [AnisetteURLProtocol.self])
        let request = XKit.HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/echo")
        let (_, body) = try await client.send(request, body: nil, baseURL: URL(string: "https://fixture.invalid/services")!, operationID: "fixture")
        let data = try await XCTUnwrap(body).reduce(into: Data()) { $0.append(contentsOf: $1) }
        XCTAssertEqual(String(data: data, encoding: .utf8), "https://fixture.invalid/services/echo")
    }

    func testInjectedURLSessionReturnsResponseAndPreservesBody() async throws {
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let client = XKitHTTPClientAdapter(boundary: .provider(config), protocolClasses: [AnisetteURLProtocol.self])
        var request = XKit.HTTPRequest(method: .post, url: config.endpoint.appendingPathComponent("echo"))
        request.headerFields[.contentType] = "application/json"
        let result = try await client.makeRequest(request, body: Data("synthetic-body".utf8))
        XCTAssertEqual(result.response.status.code, 200)
        XCTAssertEqual(result.body, Data("synthetic-body".utf8))
    }

    func testTransportRejectsAppleSecretBeforeProviderRequest() async throws {
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let client = XKitHTTPClientAdapter(boundary: .provider(config), protocolClasses: [AnisetteURLProtocol.self])
        var request = XKit.HTTPRequest(url: config.endpoint.appendingPathComponent("echo"))
        request.headerFields[.authorization] = "synthetic-secret"
        do {
            _ = try await client.makeRequest(request)
            XCTFail("Provider request accepted Apple credentials")
        } catch {
            XCTAssertEqual(error as? ProvisioningNetworkError, .rejected)
        }
    }

    func testResponseStatusErrorDoesNotExposeRawServerBody() async throws {
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let client = XKitHTTPClientAdapter(boundary: .provider(config), protocolClasses: [AnisetteURLProtocol.self])
        do {
            _ = try await client.makeRequest(XKit.HTTPRequest(url: config.endpoint.appendingPathComponent("failure")))
            XCTFail("Failed response accepted")
        } catch {
            XCTAssertEqual(error as? ProvisioningNetworkError, .httpStatus(503))
            XCTAssertFalse(String(describing: error).contains("synthetic-server-secret"))
        }
    }

    func testTimeoutHasSafeErrorAndCancellationIsPreserved() async throws {
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let client = XKitHTTPClientAdapter(boundary: .provider(config), protocolClasses: [AnisetteURLProtocol.self])
        do {
            _ = try await client.makeRequest(XKit.HTTPRequest(url: config.endpoint.appendingPathComponent("timeout")))
            XCTFail("Timeout accepted")
        } catch { XCTAssertEqual(error as? ProvisioningNetworkError, .transport) }
        let task = Task {
            try Task.checkCancellation()
            return try await client.makeRequest(XKit.HTTPRequest(url: config.endpoint.appendingPathComponent("echo")))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWebSocketValidatesEndpointBeforeOpeningConnection() async throws {
        let config = try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!)
        let client = XKitHTTPClientAdapter(boundary: .provider(config))
        do { _ = try await client.makeWebSocket(url: URL(string: "wss://external.invalid/socket")!); XCTFail("Wrong origin accepted") }
        catch { XCTAssertEqual(error as? ProvisioningNetworkError, .rejected) }
    }
}

private final class ProfileConflictURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let data = Data(#"{"errors":[{"code":"ENTITY_ERROR","detail":"There is already a current iOS Development profile for this App ID. synthetic-server-secret"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RegistrationConflictURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let json = request.url?.path.hasSuffix("/unknown") == true
            ? #"{"errors":[{"code":"UNKNOWN","detail":"synthetic-server-secret"}]}"#
            : #"{"errors":[{"code":"ENTITY_ERROR.ATTRIBUTE.INVALID","detail":"An App ID with Identifier 'synthetic-server-secret' is not available. Please enter a different string."}]}"#
        let data = Data(json.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AnisetteURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let failure = request.url!.path == "/failure"
        let response = HTTPURLResponse(url: request.url!, statusCode: failure ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        if request.url!.path == "/services/echo" { data = Data(request.url!.absoluteString.utf8) }
        client?.urlProtocol(self, didLoad: failure ? Data("synthetic-server-secret".utf8) : data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
