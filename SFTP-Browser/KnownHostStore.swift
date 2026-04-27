//
//  KnownHostStore.swift
//  SFTP-Browser
//
//  Created by OpenAI on 4/27/26.
//

import Citadel
import CryptoKit
import Foundation
import NIO
import NIOSSH

struct HostKeyDetails: Codable, Equatable, Sendable {
    let host: String
    let port: Int
    let algorithm: String
    let fingerprint: String
    let openSSHPublicKey: String
    let trustedAt: Date
}

enum HostKeyValidationError: LocalizedError, Sendable {
    case unknown(presented: HostKeyDetails)
    case changed(expected: HostKeyDetails, presented: HostKeyDetails)

    var presented: HostKeyDetails {
        switch self {
        case .unknown(let presented):
            return presented
        case .changed(_, let presented):
            return presented
        }
    }

    var errorDescription: String? {
        switch self {
        case .unknown(let presented):
            return "The host key for \(presented.host):\(presented.port) has not been trusted yet."
        case .changed(let expected, let presented):
            return "The host key for \(presented.host):\(presented.port) does not match the trusted key from \(expected.trustedAt.formatted(date: .abbreviated, time: .shortened))."
        }
    }
}

struct HostKeyRejectedError: LocalizedError {
    var errorDescription: String? {
        "Host key was not trusted."
    }
}

struct KnownHostStore: Sendable {
    private let defaultsKey = "trusted-sftp-host-keys"

    func validator(host: String, port: Int) -> SSHHostKeyValidator {
        SSHHostKeyValidator.custom(KnownHostValidator(host: host, port: port, store: self))
    }

    func trustedHostKey(host: String, port: Int) -> HostKeyDetails? {
        records()[Self.key(host: host, port: port)]
    }

    func trust(_ details: HostKeyDetails) {
        var records = records()
        records[Self.key(host: details.host, port: details.port)] = HostKeyDetails(
            host: details.host,
            port: details.port,
            algorithm: details.algorithm,
            fingerprint: details.fingerprint,
            openSSHPublicKey: details.openSSHPublicKey,
            trustedAt: Date()
        )
        save(records)
    }

    func details(for hostKey: NIOSSHPublicKey, host: String, port: Int) -> HostKeyDetails {
        let openSSHPublicKey = String(openSSHPublicKey: hostKey)
        let components = openSSHPublicKey.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let algorithm = components.first.map(String.init) ?? "unknown"
        let keyData = components.dropFirst().first.map(String.init) ?? ""

        return HostKeyDetails(
            host: Self.normalizedHost(host),
            port: port,
            algorithm: algorithm,
            fingerprint: Self.fingerprint(keyData: keyData),
            openSSHPublicKey: openSSHPublicKey,
            trustedAt: Date()
        )
    }

    private func records() -> [String: HostKeyDetails] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return [:]
        }

        return (try? JSONDecoder().decode([String: HostKeyDetails].self, from: data)) ?? [:]
    }

    private func save(_ records: [String: HostKeyDetails]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func key(host: String, port: Int) -> String {
        "\(normalizedHost(host))|\(port)"
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func fingerprint(keyData: String) -> String {
        guard let data = Data(base64Encoded: keyData) else {
            return "SHA256:unknown"
        }

        let digest = SHA256.hash(data: data)
        let base64Digest = Data(digest)
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64Digest)"
    }
}

private final class KnownHostValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let store: KnownHostStore

    init(host: String, port: Int, store: KnownHostStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = store.details(for: hostKey, host: host, port: port)

        guard let expected = store.trustedHostKey(host: host, port: port) else {
            validationCompletePromise.fail(HostKeyValidationError.unknown(presented: presented))
            return
        }

        if expected.openSSHPublicKey == presented.openSSHPublicKey {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(HostKeyValidationError.changed(expected: expected, presented: presented))
        }
    }
}
