import Foundation

struct AnisetteProviderConfiguration: Equatable, Sendable {
    let endpoint: URL
    var providerID: String { "omnisette-v3:" + endpoint.absoluteString }
    var privacySummary: String {
        "提供方：\(endpoint.absoluteString)。该服务接收本地 UUID、ADI 注册握手消息和 ADI blob，并可看到来源 IP。"
    }

    init(endpoint: URL) throws {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              ["https", "wss"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw ProvisioningNetworkError.rejected }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let canonical = parts.url else { throw ProvisioningNetworkError.rejected }
        self.endpoint = canonical
    }
}

enum ProvisioningNetworkError: Error, Equatable {
    case rejected, transport, invalidResponse, httpStatus(Int)
}

enum ProvisioningNetworkBoundary: Sendable {
    case apple
    case provider(AnisetteProviderConfiguration)

    func validate(_ request: URLRequest, webSocket: Bool = false) throws {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == (webSocket ? "wss" : "https"),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.host?.lowercased() else { throw ProvisioningNetworkError.rejected }
        switch self {
        case .apple:
            guard !webSocket, (parts.port ?? 443) == 443,
                  ["gsa.apple.com", "developerservices1.apple.com", "developerservices2.apple.com"].contains(host)
            else { throw ProvisioningNetworkError.rejected }
        case .provider(let config):
            guard host == config.endpoint.host?.lowercased(),
                  (parts.port ?? 443) == (config.endpoint.port ?? 443), parts.query == nil
            else { throw ProvisioningNetworkError.rejected }
            // An allowlist also blocks future Apple headers unknown to this release.
            let allowed = Set(["accept", "content-type", "content-length", "user-agent"])
            guard (request.allHTTPHeaderFields ?? [:]).keys.allSatisfy({ allowed.contains($0.lowercased()) })
            else { throw ProvisioningNetworkError.rejected }
        }
    }

    func permitsRedirect(from: URLRequest, to: URLRequest) -> Bool {
        guard let a = from.url, let b = to.url,
              a.scheme?.lowercased() == b.scheme?.lowercased(),
              a.host?.lowercased() == b.host?.lowercased(),
              (a.port ?? 443) == (b.port ?? 443),
              (try? validate(to, webSocket: b.scheme?.lowercased() == "wss")) != nil
        else { return false }
        return true
    }
}
