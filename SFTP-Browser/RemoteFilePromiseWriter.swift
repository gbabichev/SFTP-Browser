//
//  RemoteFilePromiseWriter.swift
//  SFTP-Browser
//
//  Created by Codex on 4/27/26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

final class RemoteFilePromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    typealias DownloadHandler = @MainActor @Sendable (URL) async throws -> Void

    let item: RemoteItem

    private let download: DownloadHandler

    init(
        item: RemoteItem,
        download: @escaping DownloadHandler
    ) {
        self.item = item
        self.download = download
        super.init()
    }

    var fileType: String {
        let pathExtension = (item.name as NSString).pathExtension
        return UTType(filenameExtension: pathExtension)?.identifier ?? UTType.data.identifier
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let destinationURL = url.hasDirectoryPath ? url.appendingPathComponent(item.name) : url
        Task {
            do {
                try await download(destinationURL)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
