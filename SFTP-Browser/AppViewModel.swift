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
    @Published var remotePath = "/"
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var isBusyOverlayVisible = false
    @Published var canCancelBusyOperation = false
    @Published var isCancellingBusyOperation = false
    @Published var busyMessage = "Working..."
    @Published var transferProgress: Double?
    @Published var transferProgressText = ""
    @Published var errorMessage: String?
    @Published var items: [RemoteItem] = []
    @Published var selectedItemIDs = Set<RemoteItem.ID>()

    private let service: SFTPService
    private var currentBusyTask: Task<Void, Never>?
    private var currentTransferTask: Task<Void, any Error>?
    private var busyOverlayDelayTask: Task<Void, Never>?
    private var transferStartedAt: Date?
    private var lastTransferUIUpdateAt: Date?
    private var lastDisplayedCompletedBytes: Int64 = 0

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
            if !transferProgressText.isEmpty {
                return "\(busyMessage) \(transferProgressText)"
            }
            return busyMessage
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
        startBusyOperation(message: "Connecting...") {
            self.remotePath = self.remotePath.normalizedRemotePath()
            let config = self.connectionConfig()
            let listed = try await self.service.listDirectory(config: config, path: self.remotePath)
            self.items = listed
            self.isConnected = true
        }
    }

    func disconnect() {
        isConnected = false
        items = []
        selectedItemIDs.removeAll()
        errorMessage = nil
    }

    func refresh() {
        startBusyOperation(message: "Refreshing...") {
            try await self.loadCurrentDirectory()
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            upload(panel.urls)
        }
    }

    func upload(_ urls: [URL]) {
        let fileURLs = urls.filter(Self.isRegularFile)
        guard !fileURLs.isEmpty else {
            errorMessage = "Drop one or more files to upload."
            return
        }

        startBusyOperation(
            message: fileURLs.count == 1 ? "Uploading \(fileURLs[0].lastPathComponent)..." : "Uploading \(fileURLs.count) files...",
            canCancel: true
        ) {
            let totalBytes = fileURLs.map(Self.localFileSize).reduce(0, +)
            var completedBeforeCurrentFile: Int64 = 0
            self.updateTransferProgress(
                TransferProgress(completedBytes: 0, totalBytes: totalBytes > 0 ? totalBytes : nil)
            )

            for url in fileURLs {
                try Task.checkCancellation()
                let completedBeforeFile = completedBeforeCurrentFile
                try await self.service.uploadFile(
                    config: self.connectionConfig(),
                    localURL: url,
                    remotePath: self.remotePath,
                    progress: { [weak self] progress in
                        let aggregateProgress = TransferProgress(
                            completedBytes: completedBeforeFile + progress.completedBytes,
                            totalBytes: totalBytes > 0 ? totalBytes : progress.totalBytes
                        )
                        await self?.updateTransferProgress(aggregateProgress)
                    }
                )
                completedBeforeCurrentFile += Self.localFileSize(url)
            }

            try Task.checkCancellation()
            try await self.loadCurrentDirectory()
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
            startBusyOperation(message: "Downloading \(selectedItem.name)...", canCancel: true) {
                try await self.service.downloadFile(
                    config: self.connectionConfig(),
                    remoteFilePath: remoteFile,
                    localURL: url,
                    progress: self.transferProgressHandler()
                )
            }
        }
    }

    func createFolder() {
        guard let folderName = promptForFolderName() else {
            return
        }

        let folderPath = remotePath.appendingRemotePathComponent(folderName)
        startBusyOperation(message: "Creating \(folderName)...") {
            try await self.service.createDirectory(config: self.connectionConfig(), remotePath: folderPath)
            try await self.loadCurrentDirectory()
        }
    }

    func rename(_ item: RemoteItem) {
        guard let newName = promptForRename(currentName: item.name) else {
            return
        }

        let oldPath = remotePath.appendingRemotePathComponent(item.name)
        let newPath = remotePath.appendingRemotePathComponent(newName)

        startBusyOperation(message: "Renaming \(item.name)...") {
            try await self.service.renameItem(config: self.connectionConfig(), oldPath: oldPath, newPath: newPath)
            try await self.loadCurrentDirectory()
        }
    }

    func delete(_ item: RemoteItem) {
        guard confirmDelete(item) else {
            return
        }

        let itemPath = remotePath.appendingRemotePathComponent(item.name)
        startBusyOperation(message: "Deleting \(item.name)...") {
            try await self.service.deleteItem(config: self.connectionConfig(), remotePath: itemPath, isDirectory: item.isDirectory)
            try await self.loadCurrentDirectory()
        }
    }

    func cancelBusyOperation() {
        guard canCancelBusyOperation, !isCancellingBusyOperation else {
            return
        }

        isCancellingBusyOperation = true
        busyMessage = "Cancelling..."
        currentBusyTask?.cancel()
        currentTransferTask?.cancel()
    }

    func filePromiseWriter(for item: RemoteItem) -> RemoteFilePromiseWriter? {
        guard isConnected, !isBusy, !item.isDirectory else {
            return nil
        }

        let promisedRemoteFilePath = remotePath.appendingRemotePathComponent(item.name)
        return RemoteFilePromiseWriter(
            item: item
        ) { [weak self] destinationURL in
            guard let self else {
                throw CancellationError()
            }

            try await self.downloadPromisedFile(
                item: item,
                remoteFilePath: promisedRemoteFilePath,
                localURL: destinationURL
            )
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

        startBusyOperation(
            message: files.count == 1 ? "Downloading \(files[0].name)..." : "Downloading \(files.count) files...",
            canCancel: true
        ) {
            let totalBytes = files.map(\.sizeBytes).reduce(0, +)
            var completedBeforeCurrentFile: Int64 = 0
            self.updateTransferProgress(
                TransferProgress(completedBytes: 0, totalBytes: totalBytes > 0 ? totalBytes : nil)
            )

            for file in files {
                try Task.checkCancellation()
                let remoteFile = self.remotePath.appendingRemotePathComponent(file.name)
                let localURL = folderURL.appendingPathComponent(file.name)
                let completedBeforeFile = completedBeforeCurrentFile
                try await self.service.downloadFile(
                    config: self.connectionConfig(),
                    remoteFilePath: remoteFile,
                    localURL: localURL,
                    progress: { [weak self] progress in
                        let aggregateProgress = TransferProgress(
                            completedBytes: completedBeforeFile + progress.completedBytes,
                            totalBytes: totalBytes > 0 ? totalBytes : progress.totalBytes
                        )
                        await self?.updateTransferProgress(aggregateProgress)
                    }
                )
                completedBeforeCurrentFile += file.sizeBytes
            }
        }
    }

    private func downloadPromisedFile(item: RemoteItem, remoteFilePath: String, localURL: URL) async throws {
        guard !isBusy else {
            throw AppOperationError.busy
        }

        try await runBusyThrowing(message: "Downloading \(item.name)...", canCancel: true) {
            self.updateTransferProgress(
                TransferProgress(completedBytes: 0, totalBytes: item.sizeBytes > 0 ? item.sizeBytes : nil)
            )

            let transferTask = Task { @MainActor in
                try await self.service.downloadFile(
                    config: self.connectionConfig(),
                    remoteFilePath: remoteFilePath,
                    localURL: localURL,
                    progress: self.transferProgressHandler()
                )
            }

            self.currentTransferTask = transferTask
            try await transferTask.value
        }
    }

    private func promptForFolderName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new remote folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = "Untitled Folder"
        textField.selectText(nil)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRemoteItemName(folderName) else {
            return nil
        }
        return folderName
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
        guard newName != currentName, isValidRemoteItemName(newName) else {
            return nil
        }
        return newName
    }

    private func isValidRemoteItemName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
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

    private func startBusyOperation(
        message: String = "Working...",
        canCancel: Bool = false,
        _ work: @escaping () async throws -> Void
    ) {
        guard !isBusy else {
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.runBusy(message: message, canCancel: canCancel, work)
        }
        currentBusyTask = task
    }

    private func runBusy(message: String = "Working...", canCancel: Bool = false, _ work: @escaping () async throws -> Void) async {
        do {
            try await runBusyThrowing(message: message, canCancel: canCancel, work)
        } catch {
            return
        }
    }

    private func runBusyThrowing(message: String = "Working...", canCancel: Bool = false, _ work: @escaping () async throws -> Void) async throws {
        errorMessage = nil
        transferProgress = nil
        transferProgressText = ""
        resetTransferTiming()
        busyMessage = message
        isBusy = true
        canCancelBusyOperation = canCancel
        isCancellingBusyOperation = false
        showBusyOverlay(afterDelay: canCancel)
        defer {
            busyOverlayDelayTask?.cancel()
            busyOverlayDelayTask = nil
            isBusy = false
            isBusyOverlayVisible = false
            canCancelBusyOperation = false
            isCancellingBusyOperation = false
            busyMessage = "Working..."
            transferProgress = nil
            transferProgressText = ""
            currentBusyTask = nil
            currentTransferTask = nil
            resetTransferTiming()
        }
        do {
            try await work()
        } catch {
            if error is CancellationError {
                errorMessage = "Transfer cancelled."
            } else {
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    private func showBusyOverlay(afterDelay: Bool) {
        busyOverlayDelayTask?.cancel()
        isBusyOverlayVisible = false

        guard afterDelay else {
            isBusyOverlayVisible = true
            return
        }

        busyOverlayDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.transferOverlayDelay))
            guard let self, !Task.isCancelled, self.isBusy, self.canCancelBusyOperation else {
                return
            }

            self.isBusyOverlayVisible = true
        }
    }

    private func transferProgressHandler() -> TransferProgressHandler {
        { [weak self] progress in
            await self?.updateTransferProgress(progress)
        }
    }

    private func updateTransferProgress(_ progress: TransferProgress) {
        let now = Date()
        if transferStartedAt == nil {
            transferStartedAt = now
        }

        guard shouldRenderTransferProgress(progress, now: now) else {
            return
        }

        lastTransferUIUpdateAt = now
        lastDisplayedCompletedBytes = progress.completedBytes

        if let totalBytes = progress.totalBytes, totalBytes > 0 {
            let fraction = min(max(Double(progress.completedBytes) / Double(totalBytes), 0), 1)
            transferProgress = fraction
            transferProgressText = transferStatusText(
                completedBytes: progress.completedBytes,
                totalBytes: totalBytes,
                now: now
            )
        } else {
            transferProgress = nil
            transferProgressText = "\(Self.byteCountFormatter.string(fromByteCount: progress.completedBytes)) transferred"
        }
    }

    private func shouldRenderTransferProgress(_ progress: TransferProgress, now: Date) -> Bool {
        let totalBytes = progress.totalBytes ?? 0
        let isInitial = progress.completedBytes == 0
        let isComplete = totalBytes > 0 && progress.completedBytes >= totalBytes
        guard !isInitial, !isComplete else {
            return true
        }

        guard let lastTransferUIUpdateAt else {
            return true
        }

        let elapsedSinceLastUpdate = now.timeIntervalSince(lastTransferUIUpdateAt)
        let byteDelta = progress.completedBytes - lastDisplayedCompletedBytes
        let fractionDelta = totalBytes > 0 ? Double(byteDelta) / Double(totalBytes) : 0

        return elapsedSinceLastUpdate >= Self.minimumTransferUIUpdateInterval
            || byteDelta >= Self.minimumTransferByteUpdate
            || fractionDelta >= Self.minimumTransferFractionUpdate
    }

    private func transferStatusText(completedBytes: Int64, totalBytes: Int64, now: Date) -> String {
        let completed = Self.byteCountFormatter.string(fromByteCount: completedBytes)
        let total = Self.byteCountFormatter.string(fromByteCount: totalBytes)

        guard let etaText = transferETAText(completedBytes: completedBytes, totalBytes: totalBytes, now: now) else {
            return "\(completed) of \(total)"
        }

        return "\(completed) of \(total) - ETA \(etaText)"
    }

    private func transferETAText(completedBytes: Int64, totalBytes: Int64, now: Date) -> String? {
        guard
            completedBytes > 0,
            totalBytes > completedBytes,
            let transferStartedAt
        else {
            return nil
        }

        let elapsed = now.timeIntervalSince(transferStartedAt)
        guard elapsed >= 1 else {
            return nil
        }

        let bytesPerSecond = Double(completedBytes) / elapsed
        guard bytesPerSecond > 0 else {
            return nil
        }

        let remainingSeconds = Double(totalBytes - completedBytes) / bytesPerSecond
        return Self.durationFormatter.string(from: remainingSeconds)
    }

    private func resetTransferTiming() {
        transferStartedAt = nil
        lastTransferUIUpdateAt = nil
        lastDisplayedCompletedBytes = 0
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let minimumTransferUIUpdateInterval: TimeInterval = 0.25
    private static let minimumTransferByteUpdate: Int64 = 1_000_000
    private static let minimumTransferFractionUpdate = 0.01
    private static let transferOverlayDelay = 1.5

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func localFileSize(_ url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return Int64(size)
    }
}

private enum AppOperationError: LocalizedError {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another operation is already running."
        }
    }
}

private extension String {
    func normalizedRemotePath() -> String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed.trimmingTrailingSlash()
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
            return "/"
        }
        guard let slashIndex = base.lastIndex(of: "/") else {
            return "/"
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
