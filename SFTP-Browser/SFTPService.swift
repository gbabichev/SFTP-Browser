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
    let sizeBytes: Int64

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct TransferProgress: Sendable {
    let completedBytes: Int64
    let totalBytes: Int64?
}

typealias TransferProgressHandler = @Sendable (TransferProgress) async -> Void

protocol SFTPService: Sendable {
    func listDirectory(config: SFTPConnectionConfig, path: String) async throws -> [RemoteItem]
    func uploadFile(config: SFTPConnectionConfig, localURL: URL, remotePath: String, progress: TransferProgressHandler?) async throws
    func downloadFile(config: SFTPConnectionConfig, remoteFilePath: String, localURL: URL, progress: TransferProgressHandler?) async throws
    func createDirectory(config: SFTPConnectionConfig, remotePath: String) async throws
    func renameItem(config: SFTPConnectionConfig, oldPath: String, newPath: String) async throws
    func deleteItem(config: SFTPConnectionConfig, remotePath: String, isDirectory: Bool) async throws
}
