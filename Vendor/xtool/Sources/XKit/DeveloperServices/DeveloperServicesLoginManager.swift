//
//  DeveloperServicesLoginManager.swift
//  XKit
//
//  Created by Kabir Oberai on 10/04/20.
//  Copyright © 2020 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

public struct DeveloperServicesLoginToken: Codable, Sendable {
    public let adsid: String
    public let token: String
    public let expiry: Date

    public init(adsid: String, token: String, expiry: Date) {
        self.adsid = adsid
        self.token = token
        self.expiry = expiry
    }
}

public struct DeveloperServicesLoginManager: Sendable {

    /// Public, payload-free classification for embedding apps. Raw GrandSlam
    /// errors can contain server-supplied strings and must not reach app logs.
    public enum AuthenticationFailure: Sendable {
        case invalidCredentials, invalidVerificationCode, cancelled, invalidAnisette, failedSecondaryAuth
        case service(Int)
    }

    public static func authenticationFailure(for error: Swift.Error) -> AuthenticationFailure? {
        if let error = error as? GrandSlamOperationError {
            switch error.code {
            case -20101, -22406: return .invalidCredentials
            case -21669: return .invalidVerificationCode
            case -22421: return .invalidAnisette
            default: return .service(error.code)
            }
        }
        if let error = error as? GrandSlamTwoFactorAuthenticateOperation.Error {
            switch error {
            case .incorrectVerificationCode: return .invalidVerificationCode
            case .userCancelled: return .cancelled
            }
        }
        if let error = error as? GrandSlamAuthenticateOperation.Error, case .failedSecondaryAuth = error {
            return .failedSecondaryAuth
        }
        return nil
    }

    public enum Error: Swift.Error {
        case missingLoginToken
    }

    private let client = GrandSlamClient()

    public init() {}

    private func logIn(
        withLoginData loginData: GrandSlamLoginData
    ) async throws -> DeveloperServicesLoginToken {
        let tokens = try await GrandSlamFetchAppTokensOperation(
            client: client,
            apps: [.xcode],
            loginData: loginData
        ).perform()
        guard let token = tokens[.xcode]
            else { throw Error.missingLoginToken }
        return .init(adsid: loginData.adsid, token: token.value, expiry: token.expiry)
    }

    public func logIn(
        withUsername username: String,
        password: String,
        twoFactorDelegate: TwoFactorAuthDelegate
    ) async throws -> DeveloperServicesLoginToken {
        let loginData = try await GrandSlamAuthenticateOperation(
            client: client,
            // GSA requires Apple IDs in lowercase for SRP
            username: username.lowercased(),
            password: password,
            twoFactorDelegate: twoFactorDelegate
        ).authenticate()
        _ = twoFactorDelegate
        return try await self.logIn(withLoginData: loginData)
    }

}
