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
    private let knownHostStore: KnownHostStore

    init(knownHostStore: KnownHostStore) {
        self.knownHostStore = knownHostStore
    }

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
            await progress?(TransferProgress(completedBytes: 0, totalBytes: totalBytes))
            _ = try await uploadLocalFile(
                sftp: sftp,
                localURL: localURL,
                remoteFilePath: destinationPath,
                completedBytes: 0,
                totalBytes: totalBytes,
                progress: progress
            )
        }
    }

    func uploadItems(
        config: SFTPConnectionConfig,
        localURLs: [URL],
        remoteDirectoryPath: String,
        progress: TransferProgressHandler?
    ) async throws {
        let totalBytes = localURLs.map(Self.localItemSize).reduce(0, +)
        let progressTotal = totalBytes > 0 ? totalBytes : nil

        try await withSFTP(config: config) { sftp in
            var completedBytes: Int64 = 0
            await progress?(TransferProgress(completedBytes: 0, totalBytes: progressTotal))

            for localURL in localURLs {
                try Task.checkCancellation()
                let remotePath = appendingRemotePathComponent(remoteDirectoryPath, localURL.lastPathComponent)
                completedBytes = try await uploadLocalItem(
                    sftp: sftp,
                    localURL: localURL,
                    remotePath: remotePath,
                    completedBytes: completedBytes,
                    totalBytes: progressTotal,
                    progress: progress
                )
            }
        }
    }

    func downloadFile(
        config: SFTPConnectionConfig,
        remoteFilePath: String,
        localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        try await withSFTP(config: config) { sftp in
            let totalBytes = try? await remoteFileSize(sftp: sftp, remoteFilePath: remoteFilePath)
            await progress?(TransferProgress(completedBytes: 0, totalBytes: totalBytes))
            _ = try await downloadRemoteFile(
                sftp: sftp,
                remoteFilePath: remoteFilePath,
                localURL: localURL,
                completedBytes: 0,
                totalBytes: totalBytes,
                progress: progress
            )
        }
    }

    func downloadItems(
        config: SFTPConnectionConfig,
        remoteItems: [RemoteItem],
        remoteDirectoryPath: String,
        localDirectoryURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        try await withSFTP(config: config) { sftp in
            var totalBytes: Int64 = 0
            for item in remoteItems {
                let remotePath = appendingRemotePathComponent(remoteDirectoryPath, item.name)
                totalBytes += try await remoteItemSize(sftp: sftp, remotePath: remotePath, isDirectory: item.isDirectory)
            }
            let progressTotal = totalBytes > 0 ? totalBytes : nil

            var completedBytes: Int64 = 0
            await progress?(TransferProgress(completedBytes: 0, totalBytes: progressTotal))

            for item in remoteItems {
                try Task.checkCancellation()
                let remotePath = appendingRemotePathComponent(remoteDirectoryPath, item.name)
                let localURL = localDirectoryURL.appendingPathComponent(item.name)
                completedBytes = try await downloadRemoteItem(
                    sftp: sftp,
                    remotePath: remotePath,
                    isDirectory: item.isDirectory,
                    localURL: localURL,
                    completedBytes: completedBytes,
                    totalBytes: progressTotal,
                    progress: progress
                )
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
            try await deleteRemoteItem(sftp: sftp, remotePath: remotePath, isDirectory: isDirectory)
        }
    }

    private func uploadLocalItem(
        sftp: SFTPClient,
        localURL: URL,
        remotePath: String,
        completedBytes: Int64,
        totalBytes: Int64?,
        progress: TransferProgressHandler?
    ) async throws -> Int64 {
        if Self.isDirectory(localURL) {
            try await ensureRemoteDirectory(sftp: sftp, remotePath: remotePath)
            let childURLs = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            var latestCompletedBytes = completedBytes
            for childURL in childURLs {
                try Task.checkCancellation()
                latestCompletedBytes = try await uploadLocalItem(
                    sftp: sftp,
                    localURL: childURL,
                    remotePath: appendingRemotePathComponent(remotePath, childURL.lastPathComponent),
                    completedBytes: latestCompletedBytes,
                    totalBytes: totalBytes,
                    progress: progress
                )
            }
            return latestCompletedBytes
        }

        guard Self.isRegularFile(localURL) else {
            return completedBytes
        }

        return try await uploadLocalFile(
            sftp: sftp,
            localURL: localURL,
            remoteFilePath: remotePath,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            progress: progress
        )
    }

    private func uploadLocalFile(
        sftp: SFTPClient,
        localURL: URL,
        remoteFilePath: String,
        completedBytes: Int64,
        totalBytes: Int64?,
        progress: TransferProgressHandler?
    ) async throws -> Int64 {
        try await sftp.withFile(
            filePath: remoteFilePath,
            flags: [.write, .create, .truncate]
        ) { remoteFile in
            let localFile = try FileHandle(forReadingFrom: localURL)
            defer {
                try? localFile.close()
            }

            var offset: UInt64 = 0
            var latestCompletedBytes = completedBytes
            while true {
                try Task.checkCancellation()
                let data = localFile.readData(ofLength: Int(chunkSize))
                guard !data.isEmpty else {
                    break
                }

                try Task.checkCancellation()
                try await remoteFile.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                latestCompletedBytes += Int64(data.count)
                await progress?(TransferProgress(completedBytes: latestCompletedBytes, totalBytes: totalBytes))
            }
            return latestCompletedBytes
        }
    }

    private func downloadRemoteItem(
        sftp: SFTPClient,
        remotePath: String,
        isDirectory: Bool,
        localURL: URL,
        completedBytes: Int64,
        totalBytes: Int64?,
        progress: TransferProgressHandler?
    ) async throws -> Int64 {
        if isDirectory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            let children = try await listRemoteItems(sftp: sftp, path: remotePath)
            var latestCompletedBytes = completedBytes
            for child in children {
                try Task.checkCancellation()
                latestCompletedBytes = try await downloadRemoteItem(
                    sftp: sftp,
                    remotePath: appendingRemotePathComponent(remotePath, child.name),
                    isDirectory: child.isDirectory,
                    localURL: localURL.appendingPathComponent(child.name),
                    completedBytes: latestCompletedBytes,
                    totalBytes: totalBytes,
                    progress: progress
                )
            }
            return latestCompletedBytes
        }

        return try await downloadRemoteFile(
            sftp: sftp,
            remoteFilePath: remotePath,
            localURL: localURL,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            progress: progress
        )
    }

    private func downloadRemoteFile(
        sftp: SFTPClient,
        remoteFilePath: String,
        localURL: URL,
        completedBytes: Int64,
        totalBytes: Int64?,
        progress: TransferProgressHandler?
    ) async throws -> Int64 {
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: localURL.path) {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        }

        return try await sftp.withFile(filePath: remoteFilePath, flags: .read) { remoteFile in
            let localFile = try FileHandle(forWritingTo: localURL)
            defer {
                try? localFile.close()
            }
            try localFile.truncate(atOffset: 0)

            var offset: UInt64 = 0
            var latestCompletedBytes = completedBytes
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
                latestCompletedBytes += Int64(bytes.count)
                await progress?(TransferProgress(completedBytes: latestCompletedBytes, totalBytes: totalBytes))
            }
            return latestCompletedBytes
        }
    }

    private func deleteRemoteItem(sftp: SFTPClient, remotePath: String, isDirectory: Bool) async throws {
        if isDirectory {
            let children = try await listRemoteItems(sftp: sftp, path: remotePath)
            for child in children {
                try Task.checkCancellation()
                try await deleteRemoteItem(
                    sftp: sftp,
                    remotePath: appendingRemotePathComponent(remotePath, child.name),
                    isDirectory: child.isDirectory
                )
            }
            try await sftp.rmdir(at: remotePath)
        } else {
            try await sftp.remove(at: remotePath)
        }
    }

    private func remoteItemSize(sftp: SFTPClient, remotePath: String, isDirectory: Bool) async throws -> Int64 {
        if !isDirectory {
            return try await remoteFileSize(sftp: sftp, remoteFilePath: remotePath)
        }

        let children = try await listRemoteItems(sftp: sftp, path: remotePath)
        var totalBytes: Int64 = 0
        for child in children {
            try Task.checkCancellation()
            totalBytes += try await remoteItemSize(
                sftp: sftp,
                remotePath: appendingRemotePathComponent(remotePath, child.name),
                isDirectory: child.isDirectory
            )
        }
        return totalBytes
    }

    private func remoteFileSize(sftp: SFTPClient, remoteFilePath: String) async throws -> Int64 {
        try await sftp.withFile(filePath: remoteFilePath, flags: .read) { remoteFile in
            let attributes = try await remoteFile.readAttributes()
            return attributes.size.flatMap(Int64.init(exactly:)) ?? 0
        }
    }

    private func listRemoteItems(sftp: SFTPClient, path: String) async throws -> [RemoteItem] {
        let listings = try await sftp.listDirectory(atPath: path)
        return listings
            .flatMap(\.components)
            .filter { component in
                component.filename != "." && component.filename != ".."
            }
            .map(Self.remoteItem)
    }

    private func ensureRemoteDirectory(sftp: SFTPClient, remotePath: String) async throws {
        do {
            try await sftp.createDirectory(atPath: remotePath)
        } catch {
            // Existing directories are expected when replacing or merging uploads.
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
            hostKeyValidator: knownHostStore.validator(host: config.host, port: config.port)
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
            sizeBytes: size,
            modifiedAt: component.attributes.accessModificationTime?.modificationTime,
            permissions: permissions
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

    private static func localItemSize(at url: URL) -> Int64 {
        if isDirectory(url) {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                return 0
            }

            var totalBytes: Int64 = 0
            for case let childURL as URL in enumerator {
                guard isRegularFile(childURL) else {
                    continue
                }
                totalBytes += localFileSizeValue(at: childURL)
            }
            return totalBytes
        }

        return localFileSizeValue(at: url)
    }

    private static func localFileSizeValue(at url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return Int64(size)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
