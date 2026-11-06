import Foundation

enum DirectURLSession {
    /// 空 connectionProxyDictionary 覆盖系统代理配置——M0 实测机房代理 IP 会触发 Apple 风控
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.httpAdditionalHeaders = [:]
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return c
    }
    static func make() -> URLSession { URLSession(configuration: configuration()) }
}
