//
//  CitadelSFTPService.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import Citadel
import Foundation
import NIO

struct CitadelSFTPService: SFTPService {
    private let chunkSize: UInt32 = 256 * 1024

    func listDirectory(config: SFTPConnectionConfig, path: String) async throws -> [RemoteItem] {
        try await withSFTP(config: config) { sftp in
            let listings = try await sftp.listDirectory(atPath: path)
            return listings
                .flatMap(\.components)
                .filter { component in
                    component.filename != "." && component.filename != ".."
                }
                .map(Self.remoteItem)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }
    }

    func uploadFile(
        config: SFTPConnectionConfig,
        localURL: URL,
        remotePath: String,
        progress: TransferProgressHandler?
    ) async throws {
        let destinationPath = appendingRemotePathComponent(remotePath, localURL.lastPathComponent)
        let totalBytes = localFileSize(at: localURL)

        try await withSFTP(config: config) { sftp in
            try await sftp.withFile(
                filePath: destinationPath,
                flags: [.write, .create, .truncate]
            ) { remoteFile in
                let localFile = try FileHandle(forReadingFrom: localURL)
                defer {
                    try? localFile.close()
                }

                var offset: UInt64 = 0
                await progress?(TransferProgress(completedBytes: 0, totalBytes: totalBytes))
                while true {
                    try Task.checkCancellation()
                    let data = localFile.readData(ofLength: Int(chunkSize))
                    guard !data.isEmpty else {
                        break
                    }

                    try Task.checkCancellation()
                    try await remoteFile.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                    await progress?(TransferProgress(completedBytes: Int64(offset), totalBytes: totalBytes))
                }
            }
        }
    }

    func downloadFile(
        config: SFTPConnectionConfig,
        remoteFilePath: String,
        localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)

        try await withSFTP(config: config) { sftp in
            try await sftp.withFile(filePath: remoteFilePath, flags: .read) { remoteFile in
                let localFile = try FileHandle(forWritingTo: localURL)
                defer {
                    try? localFile.close()
                }

                var offset: UInt64 = 0
                let totalBytes = try? await remoteFile.readAttributes().size.flatMap(Int64.init(exactly:))
                await progress?(TransferProgress(completedBytes: 0, totalBytes: totalBytes))
                while true {
                    try Task.checkCancellation()
                    var buffer = try await remoteFile.read(from: offset, length: chunkSize)
                    let readableBytes = buffer.readableBytes
                    guard readableBytes > 0, let bytes = buffer.readBytes(length: readableBytes) else {
                        break
                    }

                    try Task.checkCancellation()
                    localFile.write(Data(bytes))
                    offset += UInt64(bytes.count)
                    await progress?(TransferProgress(completedBytes: Int64(offset), totalBytes: totalBytes))
                }
            }
        }
    }

    func renameItem(config: SFTPConnectionConfig, oldPath: String, newPath: String) async throws {
        try await withSFTP(config: config) { sftp in
            try await sftp.rename(at: oldPath, to: newPath)
        }
    }

    func createDirectory(config: SFTPConnectionConfig, remotePath: String) async throws {
        try await withSFTP(config: config) { sftp in
            try await sftp.createDirectory(atPath: remotePath)
        }
    }

    func deleteItem(config: SFTPConnectionConfig, remotePath: String, isDirectory: Bool) async throws {
        try await withSFTP(config: config) { sftp in
            if isDirectory {
                try await sftp.rmdir(at: remotePath)
            } else {
                try await sftp.remove(at: remotePath)
            }
        }
    }

    private func withSFTP<Result>(
        config: SFTPConnectionConfig,
        _ operation: @escaping @Sendable (SFTPClient) async throws -> Result
    ) async throws -> Result {
        let settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: {
                .passwordBased(username: config.username, password: config.password)
            },
            hostKeyValidator: .acceptAnything()
        )

        let client = try await SSHClient.connect(to: settings)
        do {
            let result = try await client.withSFTP(operation)
            try await client.close()
            return result
        } catch {
            try? await client.close()
            throw error
        }
    }

    nonisolated private static func remoteItem(from component: SFTPPathComponent) -> RemoteItem {
        let permissions = component.attributes.permissions
        let isDirectory = isDirectory(permissions: permissions, longname: component.longname)
        let size = component.attributes.size.flatMap(Int64.init(exactly:)) ?? 0

        return RemoteItem(
            name: component.filename,
            isDirectory: isDirectory,
            sizeBytes: size
        )
    }

    nonisolated private static func isDirectory(permissions: UInt32?, longname: String) -> Bool {
        let fileTypeMask: UInt32 = 0o170000
        let directoryType: UInt32 = 0o040000

        if let permissions {
            return (permissions & fileTypeMask) == directoryType
        }

        return longname.first == "d"
    }

    private func appendingRemotePathComponent(_ basePath: String, _ component: String) -> String {
        let base = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." {
            return component
        }
        if base == "/" {
            return "/" + component
        }

        return base.trimmingTrailingSlash() + "/" + component
    }

    private func localFileSize(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
