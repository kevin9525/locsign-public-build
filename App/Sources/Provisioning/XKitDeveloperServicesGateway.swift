import Foundation
import XKit
import DeveloperAPI
import Dependencies
import OpenAPIRuntime

struct XKitDeveloperServicesGateway: DeveloperServicesGateway {
    let auth: XcodeAuthData
    let provider: any AnisetteDataProvider
    let client: any HTTPClientProtocol

    func listDevices() async throws -> [DeveloperDevice] {
        try await call { api in
            var result: [DeveloperDevice] = []
            for try await page in DeveloperAPIPages(request: {
                try await api.devicesGetCollection(query: .init(filter_lbrack_platform_rbrack_: [.ios])).ok.body.json
            }, next: { $0.links.next }) {
                for device in page.data { result.append(try Self.device(device)) }
            }
            return result
        }
    }
    func registerDevice(udid: String) async throws -> DeveloperDevice {
        try await call { api in
            let response = try await api.devicesCreateInstance(body: .json(.init(data: .init(
                _type: .devices, attributes: .init(name: "LocSign iPhone", platform: .init(.ios), udid: udid)))))
            return try Self.device(response.created.body.json.data)
        }
    }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? {
        try await call { api in
            var matches: [Components.Schemas.BundleId] = []
            for try await page in DeveloperAPIPages(request: {
                try await api.bundleIdsGetCollection(query: .init(filter_lbrack_identifier_rbrack_: [identifier])).ok.body.json
            }, next: { $0.links.next }) {
                matches += page.data.filter { $0.attributes?.identifier == identifier }
            }
            guard matches.count <= 1 else { throw DeveloperServicesError.invalidResponse }
            guard let bundle = matches.first else { return nil }
            return try await Self.bundle(bundle, api: api)
        }
    }
    func createBundleID(_ identifier: String, name: String) async throws -> DeveloperBundle {
        try await call { api in
            let response = try await api.bundleIdsCreateInstance(body: .json(.init(data: .init(
                _type: .bundleIds, attributes: .init(name: name, platform: .init(.ios), identifier: identifier)))))
            return try await Self.bundle(response.created.body.json.data, api: api)
        }
    }
    func listCertificates() async throws -> [DeveloperCertificate] {
        try await call { api in
            var result: [DeveloperCertificate] = []
            for try await page in DeveloperAPIPages(request: {
                try await api.certificatesGetCollection(query: .init(filter_lbrack_certificateType_rbrack_: [.development, .iosDevelopment])).ok.body.json
            }, next: { $0.links.next }) {
                for certificate in page.data {
                    let type = certificate.attributes?.certificateType
                    let name = type?.value1?.rawValue ?? type?.value2
                    if name == "DEVELOPMENT" || name == "IOS_DEVELOPMENT" { result.append(try Self.certificate(certificate)) }
                }
            }
            return result
        }
    }
    func createDevelopmentCertificate(csr: String) async throws -> DeveloperCertificate {
        try await call { api in
            let response = try await api.certificatesCreateInstance(body: .json(.init(data: .init(
                _type: .certificates, attributes: .init(csrContent: csr, certificateType: .init(.development))))))
            return try Self.certificate(response.created.body.json.data)
        }
    }
    func revokeCertificate(id: String) async throws {
        try await call { api in
            _ = try await api.certificatesDeleteInstance(path: .init(id: id)).noContent
        }
    }
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] {
        try await call { api in
            var result: [DeveloperProfile] = []
            for try await page in DeveloperAPIPages(request: {
                try await api.bundleIdsProfilesGetToManyRelated(path: .init(id: bundleID)).ok.body.json
            }, next: { $0.links.next }) {
                for profile in page.data { result.append(try Self.profile(profile)) }
            }
            return result
        }
    }
    func createDevelopmentProfile(bundleID: String, certificateID: String, deviceID: String) async throws -> DeveloperProfile {
        try await call { api in
            let response = try await api.profilesCreateInstance(body: .json(.init(data: .init(
                _type: .profiles,
                attributes: .init(name: "LocSign " + bundleID, profileType: .init(.iosAppDevelopment)),
                relationships: .init(bundleId: .init(data: .init(_type: .bundleIds, id: bundleID)),
                    devices: .init(data: [.init(_type: .devices, id: deviceID)]),
                    certificates: .init(data: [.init(_type: .certificates, id: certificateID)]))))))
            return try Self.profile(response.created.body.json.data)
        }
    }

    private func call<T: Sendable>(_ action: @Sendable (DeveloperAPIClient) async throws -> T) async throws -> T {
        do {
            try Task.checkCancellation()
            return try await withDependencies { $0.anisetteDataProvider = provider } operation: {
                // Construct only authentication and safe status middleware. The
                // upstream convenience initializer also logs request bodies.
                let api = DeveloperAPIClient(serverURL: try Servers.Server1.url(),
                    configuration: .init(), transport: client.asOpenAPITransport,
                    middlewares: [DeveloperAPIXcodeAuthMiddleware(authData: auth), DeveloperStatusMiddleware()])
                let value = try await action(api)
                try Task.checkCancellation()
                return value
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = Self.serviceError(error) { throw error }
            if error is ProvisioningNetworkError || error is URLError { throw ProvisioningError.remote("网络连接失败，请稍后重试") }
            throw DeveloperServicesError.invalidResponse
        }
    }
    private static func serviceError(_ error: Error) -> DeveloperServicesError? {
        if let error = error as? DeveloperServicesError { return error }
        // OpenAPI wraps a middleware error without changing its original value.
        if let error = error as? ClientError { return serviceError(error.underlyingError) }
        return nil
    }
    private static func device(_ value: Components.Schemas.Device) throws -> DeveloperDevice {
        guard !value.id.isEmpty, let udid = value.attributes?.udid, !udid.isEmpty,
              let status = value.attributes?.status else { throw DeveloperServicesError.invalidResponse }
        return DeveloperDevice(id: value.id, udid: udid, enabled: (status.value1?.rawValue ?? status.value2) == "ENABLED")
    }
    private static func bundle(_ value: Components.Schemas.BundleId, api: DeveloperAPIClient) async throws -> DeveloperBundle {
        guard !value.id.isEmpty, let identifier = value.attributes?.identifier, !identifier.isEmpty else { throw DeveloperServicesError.invalidResponse }
        var capabilities: [String] = []
        for try await page in DeveloperAPIPages(request: {
            try await api.bundleIdsBundleIdCapabilitiesGetToManyRelated(path: .init(id: value.id)).ok.body.json
        }, next: { $0.links.next }) {
            for capability in page.data {
                guard let type = capability.attributes?.capabilityType,
                      let name = type.value1?.rawValue ?? type.value2 else { throw DeveloperServicesError.invalidResponse }
                capabilities.append(name)
            }
        }
        return DeveloperBundle(id: value.id, identifier: identifier, capabilities: capabilities.sorted())
    }
    private static func certificate(_ value: Components.Schemas.Certificate) throws -> DeveloperCertificate {
        guard !value.id.isEmpty, let attributes = value.attributes, let serial = attributes.serialNumber,
              !serial.isEmpty, let expiry = attributes.expirationDate else { throw DeveloperServicesError.invalidResponse }
        let der: Data?
        if let content = attributes.certificateContent {
            guard let decoded = Data(base64Encoded: content), !decoded.isEmpty else { throw DeveloperServicesError.invalidResponse }
            der = decoded
        } else { der = nil }
        return DeveloperCertificate(id: value.id, serial: serial, name: attributes.name ?? "开发证书", expiry: expiry, der: der)
    }
    private static func profile(_ value: Components.Schemas.Profile) throws -> DeveloperProfile {
        guard !value.id.isEmpty, let content = value.attributes?.profileContent,
              let data = Data(base64Encoded: content), !data.isEmpty else { throw DeveloperServicesError.invalidResponse }
        return DeveloperProfile(id: value.id, content: data)
    }
}

private struct DeveloperStatusMiddleware: ClientMiddleware {
    func intercept(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (XKit.HTTPRequest, HTTPBody?, URL) async throws -> (XKit.HTTPResponse, HTTPBody?)) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        let result = try await next(request, body, baseURL)
        guard (200..<300).contains(result.0.status.code) else { throw DeveloperServicesError.rejected(result.0.status.code) }
        return result
    }
}
