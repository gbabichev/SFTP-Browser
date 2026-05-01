//
//  SFTPService.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import Foundation

struct SFTPConnectionConfig: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
}

struct RemoteItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let sizeBytes: Int64
    let modifiedAt: Date?
    let permissions: UInt32?

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var modifiedDescription: String {
        guard let modifiedAt else {
            return ""
        }

        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var permissionsDescription: String {
        guard let permissions else {
            return ""
        }

        var description = isSymlink ? "l" : (isDirectory ? "d" : "-")
        for (bit, character) in [
            (UInt32(0o400), "r"), (UInt32(0o200), "w"), (UInt32(0o100), "x"),
            (UInt32(0o040), "r"), (UInt32(0o020), "w"), (UInt32(0o010), "x"),
            (UInt32(0o004), "r"), (UInt32(0o002), "w"), (UInt32(0o001), "x")
        ] {
            description += (permissions & bit) == bit ? character : "-"
        }
        return description
    }

}

struct TransferProgress: Sendable {
    let completedBytes: Int64
    let totalBytes: Int64?
}

struct DSStoreCleanupResult: Sendable {
    var removedCount = 0
    var skippedCount = 0
    var skippedPathSamples: [String] = []

    mutating func recordSkippedPath(_ path: String) {
        skippedCount += 1
        if skippedPathSamples.count < 5 {
            skippedPathSamples.append(path)
        }
    }

    mutating func merge(_ result: DSStoreCleanupResult) {
        removedCount += result.removedCount
        skippedCount += result.skippedCount

        let availableSampleSlots = max(0, 5 - skippedPathSamples.count)
        if availableSampleSlots > 0 {
            skippedPathSamples.append(contentsOf: result.skippedPathSamples.prefix(availableSampleSlots))
        }
    }
}

typealias TransferProgressHandler = @Sendable (TransferProgress) async -> Void

protocol SFTPService: Sendable {
    func listDirectory(config: SFTPConnectionConfig, path: String) async throws -> [RemoteItem]
    func uploadConflicts(config: SFTPConnectionConfig, localURLs: [URL], remoteDirectoryPath: String) async throws -> [String]
    func uploadItems(config: SFTPConnectionConfig, localURLs: [URL], remoteDirectoryPath: String, progress: TransferProgressHandler?) async throws
    func uploadFile(config: SFTPConnectionConfig, localURL: URL, remotePath: String, progress: TransferProgressHandler?) async throws
    func downloadConflicts(config: SFTPConnectionConfig, remoteItems: [RemoteItem], remoteDirectoryPath: String, localDirectoryURL: URL) async throws -> [String]
    func downloadItems(config: SFTPConnectionConfig, remoteItems: [RemoteItem], remoteDirectoryPath: String, localDirectoryURL: URL, progress: TransferProgressHandler?) async throws
    func downloadFile(config: SFTPConnectionConfig, remoteFilePath: String, localURL: URL, progress: TransferProgressHandler?) async throws
    func createDirectory(config: SFTPConnectionConfig, remotePath: String) async throws
    func renameItem(config: SFTPConnectionConfig, oldPath: String, newPath: String) async throws
    func deleteItem(config: SFTPConnectionConfig, remotePath: String, isDirectory: Bool) async throws
    func cleanDSStoreFiles(config: SFTPConnectionConfig, remotePath: String) async throws -> DSStoreCleanupResult
}
