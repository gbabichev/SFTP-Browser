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
    @Published var selectedItemIDs = Set<RemoteItem.ID>()

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

    var selectedFiles: [RemoteItem] {
        items.filter { selectedItemIDs.contains($0.id) && !$0.isDirectory }
    }

    var canDownloadSelection: Bool {
        !selectedFiles.isEmpty
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
                self.remotePath = self.remotePath.normalizedRemotePath()
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
        selectedItemIDs.removeAll()
        errorMessage = nil
    }

    func refresh() {
        Task {
            await runBusy {
                try await self.loadCurrentDirectory()
            }
        }
    }

    func submitRemotePath() {
        remotePath = remotePath.normalizedRemotePath()
        if isConnected {
            refresh()
        } else if canConnect {
            connect()
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
        let files = selectedFiles
        guard !files.isEmpty else { return }

        if files.count > 1 {
            download(files)
            return
        }

        let selectedItem = files[0]
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

    func rename(_ item: RemoteItem) {
        guard let newName = promptForRename(currentName: item.name) else {
            return
        }

        let oldPath = remotePath.appendingRemotePathComponent(item.name)
        let newPath = remotePath.appendingRemotePathComponent(newName)

        Task {
            await runBusy {
                try await self.service.renameItem(config: self.connectionConfig(), oldPath: oldPath, newPath: newPath)
                try await self.loadCurrentDirectory()
            }
        }
    }

    func delete(_ item: RemoteItem) {
        guard confirmDelete(item) else {
            return
        }

        let itemPath = remotePath.appendingRemotePathComponent(item.name)
        Task {
            await runBusy {
                try await self.service.deleteItem(config: self.connectionConfig(), remotePath: itemPath, isDirectory: item.isDirectory)
                try await self.loadCurrentDirectory()
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
        remotePath = remotePath.normalizedRemotePath()
        let listed = try await service.listDirectory(config: connectionConfig(), path: remotePath)
        items = listed
        selectedItemIDs.removeAll()
    }

    private func download(_ files: [RemoteItem]) {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder for the selected downloads."
        panel.prompt = "Download"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }

        Task {
            await runBusy {
                for file in files {
                    let remoteFile = self.remotePath.appendingRemotePathComponent(file.name)
                    let localURL = folderURL.appendingPathComponent(file.name)
                    try await self.service.downloadFile(config: self.connectionConfig(), remoteFilePath: remoteFile, localURL: localURL)
                }
            }
        }
    }

    private func promptForRename(currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for \(currentName)."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = currentName
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != currentName, !newName.contains("/") else {
            return nil
        }
        return newName
    }

    private func confirmDelete(_ item: RemoteItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(item.name)?"
        alert.informativeText = item.isDirectory
            ? "This will delete the selected remote directory if it is empty."
            : "This will delete the selected remote file."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
    func normalizedRemotePath() -> String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : trimmed.trimmingTrailingSlash()
    }

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
