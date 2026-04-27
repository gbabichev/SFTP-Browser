//
//  AppViewModel.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import AppKit
import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var host = ""
    @Published var port = 22
    @Published var username = ""
    @Published var password = ""
    @Published var remotePath = "."
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var items: [RemoteItem] = []
    @Published var selectedItem: RemoteItem?

    private let service: SFTPService

    init() {
        self.service = CitadelSFTPService()
    }

    init(service: SFTPService) {
        self.service = service
    }

    var statusText: String {
        if let errorMessage {
            return errorMessage
        }
        if isBusy {
            return "Working..."
        }
        if isConnected {
            return "Connected to \(username)@\(host)"
        }
        return "Disconnected"
    }

    var canConnect: Bool {
        !isBusy
        && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    func connect() {
        Task {
            await runBusy {
                let config = self.connectionConfig()
                let listed = try await self.service.listDirectory(config: config, path: self.remotePath)
                self.items = listed
                self.isConnected = true
            }
        }
    }

    func disconnect() {
        isConnected = false
        items = []
        selectedItem = nil
        errorMessage = nil
    }

    func refresh() {
        Task {
            await runBusy {
                try await self.loadCurrentDirectory()
            }
        }
    }

    func open(_ item: RemoteItem) {
        guard item.isDirectory else { return }
        remotePath = remotePath.appendingRemotePathComponent(item.name)
        refresh()
    }

    func goUp() {
        remotePath = remotePath.deletingLastRemotePathComponent()
        refresh()
    }

    func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await runBusy {
                    try await self.service.uploadFile(config: self.connectionConfig(), localURL: url, remotePath: self.remotePath)
                    try await self.loadCurrentDirectory()
                }
            }
        }
    }

    func download() {
        guard let selectedItem, !selectedItem.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedItem.name
        if panel.runModal() == .OK, let url = panel.url {
            let remoteFile = remotePath.appendingRemotePathComponent(selectedItem.name)
            Task {
                await runBusy {
                    try await self.service.downloadFile(config: self.connectionConfig(), remoteFilePath: remoteFile, localURL: url)
                }
            }
        }
    }

    private func connectionConfig() -> SFTPConnectionConfig {
        SFTPConnectionConfig(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    private func loadCurrentDirectory() async throws {
        let listed = try await service.listDirectory(config: connectionConfig(), path: remotePath)
        items = listed
        selectedItem = nil
    }

    private func runBusy(_ work: @escaping () async throws -> Void) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    func appendingRemotePathComponent(_ component: String) -> String {
        let base = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." {
            return component
        }
        if base == "/" {
            return "/" + component
        }
        return base.trimmingTrailingSlash() + "/" + component
    }

    func deletingLastRemotePathComponent() -> String {
        let base = self.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlash()
        if base.isEmpty || base == "." || base == "/" {
            return "."
        }
        guard let slashIndex = base.lastIndex(of: "/") else {
            return "."
        }
        if slashIndex == base.startIndex {
            return "/"
        }
        return String(base[..<slashIndex])
    }

    private func trimmingTrailingSlash() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
