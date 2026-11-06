import Foundation
import XKit

struct LocSignRawADIProvider: RawADIProvider {
    let configuration: AnisetteProviderConfiguration
    let client: any HTTPClientProtocol

    func clientInfo() async throws -> ClientInfoWithUserAgent {
        struct Info: Decodable { let clientInfo: String; let userAgent: String }
        do {
            let body = try await client.makeRequest(HTTPRequest(url: configuration.endpoint.appendingPathComponent("v3/client_info"))).body
            let value = try Self.decoder().decode(Info.self, from: body)
            guard [value.clientInfo, value.userAgent].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\r") && !$0.contains("\n") })
            else { throw ProvisioningNetworkError.invalidResponse }
            return ClientInfoWithUserAgent(clientInfo: value.clientInfo, akdUserAgent: value.userAgent)
        } catch { throw Self.safeError(error) }
    }

    func startProvisioning(spim: Data, userID: UUID) async throws -> (any RawADIProvisioningSession, Data) {
        var parts = URLComponents(url: configuration.endpoint.appendingPathComponent("v3/provisioning_session"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        let socket = try await client.makeWebSocket(url: parts.url!)
        let connection = LocSignADIProvisioningSession(socket: socket)
        do {
            let cpim = try await withTaskCancellationHandler {
                try await connection.receive("GiveIdentifier")
                try await connection.send(["identifier": Self.rawUUID(userID).base64EncodedString()])
                try await connection.receive("GiveStartProvisioningData")
                try await connection.send(["spim": spim.base64EncodedString()])
                return try await connection.receiveData("GiveEndProvisioningData", key: "cpim")
            } onCancel: { socket.close() }
            return (connection, cpim)
        } catch { socket.close(); throw Self.safeError(error) }
    }

    func requestOTP(userID: UUID, routingInfo: inout UInt64, provisioningInfo: Data) async throws -> (machineID: Data, otp: Data) {
        struct Headers: Decodable {
            let machineID: Data
            let otp: Data
            let routing: String
            enum CodingKeys: String, CodingKey {
                case machineID = "X-Apple-I-MD-M", otp = "X-Apple-I-MD", routing = "X-Apple-I-MD-RINFO"
            }
        }
        do {
            var request = HTTPRequest(method: .post, url: configuration.endpoint.appendingPathComponent("v3/get_headers"))
            request.headerFields[.contentType] = "application/json"
            let body = try JSONEncoder().encode(["identifier": Self.rawUUID(userID).base64EncodedString(), "adi_pb": provisioningInfo.base64EncodedString()])
            let response = try await client.makeRequest(request, body: body).body
            let value = try Self.decoder().decode(Headers.self, from: response)
            guard let routing = UInt64(value.routing), !value.machineID.isEmpty, !value.otp.isEmpty else { throw ProvisioningNetworkError.invalidResponse }
            try Task.checkCancellation()
            routingInfo = routing
            return (value.machineID, value.otp)
        } catch { throw Self.safeError(error) }
    }

    private static func rawUUID(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
    fileprivate static func safeError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        if let safe = error as? ProvisioningNetworkError { return safe }
        if error is DecodingError { return ProvisioningNetworkError.invalidResponse }
        return ProvisioningNetworkError.transport
    }
}

private final class LocSignADIProvisioningSession: RawADIProvisioningSession {
    let socket: any WebSocketSession
    init(socket: any WebSocketSession) { self.socket = socket }
    deinit { socket.close() }

    func endProvisioning(routingInfo: UInt64, ptm: Data, tk: Data) async throws -> Data {
        defer { socket.close() }
        do {
            return try await withTaskCancellationHandler {
                try await send(["ptm": ptm.base64EncodedString(), "tk": tk.base64EncodedString()])
                return try await receiveData("ProvisioningSuccess", key: "adi_pb")
            } onCancel: { self.socket.close() }
        } catch { throw LocSignRawADIProvider.safeError(error) }
    }

    func send(_ fields: [String: String]) async throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(fields)
        try await socket.send(.text(String(decoding: data, as: UTF8.self)))
    }

    func receive(_ result: String) async throws { _ = try await fields(result) }
    func receiveData(_ result: String, key: String) async throws -> Data {
        let response = try await fields(result)
        guard let value = response[key], let bytes = Data(base64Encoded: value), !bytes.isEmpty else { throw ProvisioningNetworkError.invalidResponse }
        return bytes
    }
    private func fields(_ result: String) async throws -> [String: String] {
        try Task.checkCancellation()
        let data: Data
        switch try await socket.receive() {
        case .data(let bytes): data = bytes
        case .text(let text): data = Data(text.utf8)
        }
        guard data.count <= 1024 * 1024,
              let response = try? JSONDecoder().decode([String: String].self, from: data), response["result"] == result
        else { throw ProvisioningNetworkError.invalidResponse }
        return response
    }
}
