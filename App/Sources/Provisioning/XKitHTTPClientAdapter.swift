import Foundation
import XKit
import OpenAPIRuntime
import HTTPTypesFoundation

final class XKitHTTPClientAdapter: HTTPClientProtocol, ClientTransport {
    let boundary: ProvisioningNetworkBoundary
    private let protocolClasses: [AnyClass]?

    init(boundary: ProvisioningNetworkBoundary, protocolClasses: [AnyClass]? = nil) {
        self.boundary = boundary
        self.protocolClasses = protocolClasses
    }

    var asOpenAPITransport: any ClientTransport { self }

    func send(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        try Task.checkCancellation()
        var resolved = request
        if resolved.scheme == nil && resolved.authority == nil {
            guard var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  let path = URLComponents(string: request.path ?? ""),
                  path.scheme == nil, path.host == nil, path.fragment == nil else { throw ProvisioningNetworkError.rejected }
            base.percentEncodedPath += path.percentEncodedPath
            base.percentEncodedQuery = path.percentEncodedQuery
            guard let url = base.url else { throw ProvisioningNetworkError.rejected }
            resolved = XKit.HTTPRequest(method: request.method, url: url)
            resolved.headerFields = request.headerFields
        }
        guard var urlRequest = URLRequest(httpRequest: resolved) else { throw ProvisioningNetworkError.rejected }
        try boundary.validate(urlRequest)
        if let body {
            urlRequest.httpBody = try await body.reduce(into: Data()) {
                guard $0.count + $1.count <= 8 * 1024 * 1024 else { throw ProvisioningNetworkError.rejected }
                $0.append(contentsOf: $1)
            }
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, let typedResponse = response.httpResponse,
                  data.count <= 8 * 1024 * 1024 else { throw ProvisioningNetworkError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                // Apple callers need the status (e.g. 403 to select another 2FA
                // method), but must never receive raw error bodies for logging.
                if case .apple = boundary { return (typedResponse, nil) }
                throw ProvisioningNetworkError.httpStatus(response.statusCode)
            }
            return (typedResponse, HTTPBody(data))
        } catch { throw Self.safeError(error) }
    }

    func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        try Task.checkCancellation()
        let request = URLRequest(url: url)
        try boundary.validate(request, webSocket: true)
        let session = makeSession()
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1024 * 1024
        task.resume()
        return PrivateWebSocket(session: session, task: task)
    }

    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await perform(XKitHTTPClientAdapter(boundary: boundary, protocolClasses: protocolClasses))
    }

    private func makeSession() -> URLSession {
        let config = DirectURLSession.configuration()
        config.timeoutIntervalForResource = 60
        if let protocolClasses { config.protocolClasses = protocolClasses }
        // No authentication challenge override: HTTPS and WSS use system trust.
        return URLSession(configuration: config, delegate: PrivateRedirectDelegate(boundary: boundary), delegateQueue: nil)
    }

    fileprivate static func safeError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        return (error as? ProvisioningNetworkError) ?? ProvisioningNetworkError.transport
    }
}

private final class PrivateRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let boundary: ProvisioningNetworkBoundary
    init(boundary: ProvisioningNetworkBoundary) { self.boundary = boundary }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, boundary.permitsRedirect(from: original, to: request) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class PrivateWebSocket: WebSocketSession {
    let session: URLSession
    let task: URLSessionWebSocketTask
    init(session: URLSession, task: URLSessionWebSocketTask) { self.session = session; self.task = task }
    deinit { close() }

    func receive() async throws -> WebSocketMessage {
        let timeout = deadline()
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                switch try await task.receive() {
                case .data(let data): return .data(data)
                case .string(let text): return .text(text)
                @unknown default: throw ProvisioningNetworkError.invalidResponse
                }
            } onCancel: { self.close() }
        } catch { throw XKitHTTPClientAdapter.safeError(error) }
    }

    func send(_ message: WebSocketMessage) async throws {
        let timeout = deadline()
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let output: URLSessionWebSocketTask.Message
                switch message {
                case .text(let text): output = .string(text)
                case .data(let data): output = .data(data)
                }
                try await task.send(output)
            } onCancel: { self.close() }
        } catch { throw XKitHTTPClientAdapter.safeError(error) }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func deadline() -> Task<Void, Never> {
        Task { [task] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { return }
            task.cancel(with: .goingAway, reason: nil)
        }
    }
}
