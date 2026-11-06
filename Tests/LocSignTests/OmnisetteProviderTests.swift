import XCTest
import XKit
import OpenAPIRuntime
@testable import LocSign

final class OmnisetteProviderTests: XCTestCase {
    func testCompleteClientInfoAndOTPUseOnlyDisclosedFields() async throws {
        let client = OmnisetteFixtureClient()
        let provider = try provider(client)
        let info = try await provider.clientInfo()
        XCTAssertEqual(info.clientInfo, "synthetic-client")
        XCTAssertEqual(info.akdUserAgent, "synthetic-agent")
        var routing: UInt64 = 0
        let headers = try await provider.requestOTP(userID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, routingInfo: &routing, provisioningInfo: Data([1, 2, 3]))
        XCTAssertEqual(headers.machineID, Data([1]))
        XCTAssertEqual(headers.otp, Data([2]))
        XCTAssertEqual(routing, 42)
        let sent = try XCTUnwrap(client.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: String])
        XCTAssertEqual(json, ["identifier": "AAAAAAAAAAAAAAAAAAAAAQ==", "adi_pb": "AQID"])
    }

    func testMalformedProviderResponseIsSafeAndDoesNotChangeRoutingInfo() async throws {
        for response in ["not json synthetic-server-secret", "{}", "{\"X-Apple-I-MD-M\":\"AQ==\",\"X-Apple-I-MD\":\"Ag==\",\"X-Apple-I-MD-RINFO\":\"bad\"}"] {
            let client = OmnisetteFixtureClient(otpBody: Data(response.utf8))
            var routing: UInt64 = 7
            do {
                _ = try await provider(client).requestOTP(userID: UUID(), routingInfo: &routing, provisioningInfo: Data([1]))
                XCTFail("Malformed provider response accepted")
            } catch {
                XCTAssertEqual(error as? ProvisioningNetworkError, .invalidResponse)
                XCTAssertFalse(String(describing: error).contains("synthetic-server-secret"))
                XCTAssertEqual(routing, 7)
            }
        }
    }

    func testProvisioningWebSocketHandshakeAndClose() async throws {
        let socket = OmnisetteFixtureSocket(messages: [
            "{\"result\":\"GiveIdentifier\"}",
            "{\"result\":\"GiveStartProvisioningData\"}",
            "{\"result\":\"GiveEndProvisioningData\",\"cpim\":\"Aw==\"}",
            "{\"result\":\"ProvisioningSuccess\",\"adi_pb\":\"BA==\"}"
        ])
        let client = OmnisetteFixtureClient(socket: socket)
        let (session, cpim) = try await provider(client).startProvisioning(spim: Data([2]), userID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        XCTAssertEqual(cpim, Data([3]))
        let result = try await session.endProvisioning(routingInfo: 42, ptm: Data([5]), tk: Data([6]))
        XCTAssertEqual(result, Data([4]))
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(client.socketURL?.absoluteString, "wss://fixture.invalid/v3/provisioning_session")
        let sent = try socket.sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
        XCTAssertEqual(sent, [["identifier": "AAAAAAAAAAAAAAAAAAAAAQ=="], ["spim": "Ag=="], ["ptm": "BQ==", "tk": "Bg=="]])
    }

    func testUnexpectedHandshakeMessageClosesSocketWithoutLeakingResponse() async throws {
        let socket = OmnisetteFixtureSocket(messages: ["{\"result\":\"synthetic-secret\"}"])
        do { _ = try await provider(OmnisetteFixtureClient(socket: socket)).startProvisioning(spim: Data([1]), userID: UUID()); XCTFail("Wrong handshake accepted") }
        catch {
            XCTAssertEqual(error as? ProvisioningNetworkError, .invalidResponse)
            XCTAssertTrue(socket.closed)
            XCTAssertFalse(String(describing: error).contains("synthetic-secret"))
        }
    }

    private func provider(_ client: OmnisetteFixtureClient) throws -> LocSignRawADIProvider {
        LocSignRawADIProvider(configuration: try AnisetteProviderConfiguration(endpoint: URL(string: "https://fixture.invalid")!), client: client)
    }
}

// Network-boundary double; the real provider decodes/validates every response.
private final class OmnisetteFixtureClient: HTTPClientProtocol, ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?
    private var url: URL?
    let otpBody: Data
    let socket: OmnisetteFixtureSocket
    var lastBody: Data? { lock.withLock { body } }
    var socketURL: URL? { lock.withLock { url } }
    var asOpenAPITransport: any ClientTransport { self }
    init(otpBody: Data = Data("{\"X-Apple-I-MD-M\":\"AQ==\",\"X-Apple-I-MD\":\"Ag==\",\"X-Apple-I-MD-RINFO\":\"42\"}".utf8), socket: OmnisetteFixtureSocket = .init(messages: [])) {
        self.otpBody = otpBody
        self.socket = socket
    }
    func send(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        let bytes = try await body.mapData()
        lock.withLock { self.body = bytes }
        switch request.path {
        case "/v3/client_info": return (.init(status: .ok), HTTPBody(Data("{\"client_info\":\"synthetic-client\",\"user_agent\":\"synthetic-agent\"}".utf8)))
        case "/v3/get_headers": return (.init(status: .ok), HTTPBody(otpBody))
        default: throw ProvisioningNetworkError.rejected
        }
    }
    func makeWebSocket(url: URL) async throws -> any WebSocketSession { lock.withLock { self.url = url }; return socket }
    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T { try await perform(self) }
}

private extension Optional where Wrapped == HTTPBody {
    func mapData() async throws -> Data? {
        guard let body = self else { return nil }
        return try await body.reduce(into: Data()) { $0.append(contentsOf: $1) }
    }
}

private final class OmnisetteFixtureSocket: WebSocketSession, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String]
    private var outputs: [String] = []
    private var isClosed = false
    var sent: [String] { lock.withLock { outputs } }
    var closed: Bool { lock.withLock { isClosed } }
    init(messages: [String]) { self.messages = messages }
    func receive() async throws -> WebSocketMessage {
        try lock.withLock {
            guard !messages.isEmpty else { throw ProvisioningNetworkError.invalidResponse }
            return .text(messages.removeFirst())
        }
    }
    func send(_ message: WebSocketMessage) async throws {
        guard case .text(let text) = message else { throw ProvisioningNetworkError.invalidResponse }
        lock.withLock { outputs.append(text) }
    }
    func close() { lock.withLock { isClosed = true } }
}
