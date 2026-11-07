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
        try await call(.listDevices) { api in
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
        try await call(.registerDevice) { api in
            let response = try await api.devicesCreateInstance(body: .json(.init(data: .init(
                _type: .devices, attributes: .init(name: "LocSign iPhone", platform: .init(.ios), udid: udid)))))
            return try Self.device(response.created.body.json.data)
        }
    }
    func findExactBundleID(_ identifier: String) async throws -> DeveloperBundle? {
        try await call(.findBundle) { api in
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
        try await call(.createBundle) { api in
            let response = try await api.bundleIdsCreateInstance(body: .json(.init(data: .init(
                _type: .bundleIds, attributes: .init(name: name, platform: .init(.ios), identifier: identifier)))))
            return try await Self.bundle(response.created.body.json.data, api: api)
        }
    }
    func listCertificates() async throws -> [DeveloperCertificate] {
        try await call(.listCertificates) { api in
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
        do {
            let der = try await LegacyDevelopmentCertificateIssuer(auth: auth, provider: provider, client: client).issue(csr: csr)
            guard let parsed = try? XKit.Certificate(data: der) else {
                throw DeveloperServicesError.certificateResponse(.x509)
            }
            // The collection may omit certificateContent. Resolve the REST resource
            // using the serial parsed from the issued DER, never a legacy request ID.
            let matches = try await listCertificates().filter { parsed.hasSerialNumber($0.serial) }
            guard !matches.isEmpty else {
                throw DeveloperServicesFailure(step: .resolveCertificate, reason: .issuedCertificateMissing)
            }
            guard matches.count == 1, let issued = matches.first,
                  issued.der == nil || issued.der == der else {
                throw DeveloperServicesFailure(step: .resolveCertificate, reason: .issuedCertificateConflict)
            }
            return DeveloperCertificate(id: issued.id, serial: issued.serial, name: issued.name,
                                        expiry: issued.expiry, der: der)
        } catch {
            throw Self.failure(error, at: .createCertificate)
        }
    }
    func certificateDetails(id: String) async throws -> DeveloperCertificate {
        try await call(.readCertificate) { api in
            let response = try await api.certificatesGetInstance(path: .init(id: id),
                query: .init(fields_lbrack_certificates_rbrack_: [.name, .certificateType, .serialNumber, .expirationDate, .certificateContent]))
            let value = try response.ok.body.json.data
            let type = value.attributes?.certificateType
            let name = type?.value1?.rawValue ?? type?.value2
            guard value.id == id, name == "DEVELOPMENT" || name == "IOS_DEVELOPMENT" else {
                throw DeveloperServicesError.remoteChanged
            }
            let certificate = try Self.certificate(value)
            if let content = certificate.der {
                let der = try CertificateResponseDecoder.decode(content)
                guard let parsed = try? XKit.Certificate(data: der), parsed.hasSerialNumber(certificate.serial) else {
                    throw DeveloperServicesError.remoteChanged
                }
                return DeveloperCertificate(id: certificate.id, serial: certificate.serial, name: certificate.name,
                                            expiry: certificate.expiry, der: der)
            }
            return certificate
        }
    }
    func revokeCertificate(id: String) async throws {
        try await call(.revokeCertificate) { api in
            _ = try await api.certificatesDeleteInstance(path: .init(id: id)).noContent
        }
    }
    func listProfiles(bundleID: String) async throws -> [DeveloperProfile] {
        try await call(.listProfiles) { api in
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
        try await call(.createProfile) { api in
            let response = try await api.profilesCreateInstance(body: .json(.init(data: .init(
                _type: .profiles,
                attributes: .init(name: "LocSign " + bundleID, profileType: .init(.iosAppDevelopment)),
                relationships: .init(bundleId: .init(data: .init(_type: .bundleIds, id: bundleID)),
                    devices: .init(data: [.init(_type: .devices, id: deviceID)]),
                    certificates: .init(data: [.init(_type: .certificates, id: certificateID)]))))))
            return try Self.profile(response.created.body.json.data)
        }
    }

    private func call<T: Sendable>(_ step: DeveloperServicesStep,
                                   _ action: @Sendable (DeveloperAPIClient) async throws -> T) async throws -> T {
        do {
            try Task.checkCancellation()
            return try await withDependencies { $0.anisetteDataProvider = provider } operation: {
                // Construct only authentication and safe status middleware. The
                // upstream convenience initializer also logs request bodies.
                let api = DeveloperAPIClient(serverURL: try Servers.Server1.url(),
                    configuration: .init(dateTranscoder: AppleDeveloperDateTranscoder()), transport: client.asOpenAPITransport,
                    middlewares: [DeveloperAPIXcodeAuthMiddleware(authData: auth), DeveloperStatusMiddleware()])
                let value = try await action(api)
                try Task.checkCancellation()
                return value
            }
        } catch {
            throw Self.failure(error, at: step)
        }
    }
    private static func failure(_ error: Error, at step: DeveloperServicesStep) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        // Unwrap before classifying: middleware/transport cancellation and network
        // failures are wrapped by OpenAPI too, not just HTTP service rejections.
        if let error = error as? ClientError { return failure(error.underlyingError, at: step) }
        if let error = error as? DeveloperServicesFailure { return error }
        if let error = error as? DeveloperServicesError {
            // Preserve the exact quota signal consumed by the provisioner's
            // confirmation flow. Ordinary HTTP conflicts never become quota.
            if error == .certificateQuota { return error }
            return DeveloperServicesFailure(step: step, reason: error)
        }
        if error is ProvisioningNetworkError || error is URLError {
            return DeveloperServicesFailure(step: step, reason: .network)
        }
        return DeveloperServicesFailure(step: step, reason: .invalidResponse)
    }
    private static func device(_ value: Components.Schemas.Device) throws -> DeveloperDevice {
        guard !value.id.isEmpty, let udid = value.attributes?.udid, !udid.isEmpty,
              let status = value.attributes?.status else { throw DeveloperServicesError.invalidResponse }
        return DeveloperDevice(id: value.id, udid: udid, enabled: (status.value1?.rawValue ?? status.value2) == "ENABLED")
    }
    private static func bundle(_ value: Components.Schemas.BundleId, api: DeveloperAPIClient) async throws -> DeveloperBundle {
        guard !value.id.isEmpty, let identifier = value.attributes?.identifier, !identifier.isEmpty else { throw DeveloperServicesError.invalidResponse }
        var capabilities: [String] = []
        do {
            for try await page in DeveloperAPIPages(request: {
                try await api.bundleIdsBundleIdCapabilitiesGetToManyRelated(path: .init(id: value.id)).ok.body.json
            }, next: { $0.links.next }) {
                for capability in page.data {
                    guard let type = capability.attributes?.capabilityType,
                          let name = type.value1?.rawValue ?? type.value2 else { throw DeveloperServicesError.invalidResponse }
                    capabilities.append(name)
                }
            }
        } catch {
            throw failure(error, at: .readCapabilities)
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

// Apple responses contain both whole seconds and fractional seconds. Keep the
// runtime's synchronized formatters rather than sharing an unprotected formatter.
private struct AppleDeveloperDateTranscoder: DateTranscoder {
    private let fractional: ISO8601DateTranscoder = .iso8601WithFractionalSeconds
    private let whole: ISO8601DateTranscoder = .iso8601
    func encode(_ value: Date) throws -> String { try fractional.encode(value) }
    func decode(_ value: String) throws -> Date {
        if let date = try? fractional.decode(value) { return date }
        return try whole.decode(value)
    }
}

private struct DeveloperStatusMiddleware: ClientMiddleware {
    func intercept(_ request: XKit.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (XKit.HTTPRequest, HTTPBody?, URL) async throws -> (XKit.HTTPResponse, HTTPBody?)) async throws -> (XKit.HTTPResponse, HTTPBody?) {
        let result = try await next(request, body, baseURL)
        guard (200..<300).contains(result.0.status.code) else {
            // Injected transports may provide bodies; the live adapter already
            // classifies and discards them before they reach OpenAPI errors.
            if request.path?.split(separator: "?").first == "/v1/bundleIds", let body = result.1 {
                let data: Data?
                do {
                    data = try await body.reduce(into: Data()) {
                        guard $0.count + $1.count <= 65_536 else { throw DeveloperServicesError.invalidResponse }
                        $0.append(contentsOf: $1)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    data = nil
                }
                if let data, let rejection = DeveloperRegistrationDiagnostics.rejection(status: result.0.status.code, data: data) {
                    throw rejection
                }
            }
            throw DeveloperServicesError.rejected(result.0.status.code)
        }
        return result
    }
}
