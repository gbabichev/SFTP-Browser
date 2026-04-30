//
//  AppViewModel.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import AppKit
import Citadel
import Combine
import Darwin
import Foundation
import NIOCore
import NIOPosix
import Quartz

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
    @Published var transferJobs: [TransferJob] = []
    @Published var isTransferOverlayVisible = false
    @Published var isCancellingTransfer = false

    private let service: SFTPService
    private let knownHostStore: KnownHostStore
    private var currentBusyTask: Task<Void, Never>?
    private var currentTransferTask: Task<Void, any Error>?
    private var busyOverlayDelayTask: Task<Void, Never>?
    private var transferOverlayDelayTask: Task<Void, Never>?
    private var transferQueueTask: Task<Void, Never>?
    private var queuedTransferOperations: [QueuedTransferOperation] = []
    private var currentBusyOperationID: UUID?
    private var currentBusyCancellationMessage = "Operation cancelled."
    private var currentTransferJobID: TransferJob.ID?
    private var transferStartedAt: Date?
    private var lastTransferUIUpdateAt: Date?
    private var lastDisplayedCompletedBytes: Int64 = 0
    private let quickLookPreviewController = QuickLookPreviewController()

    init() {
        let knownHostStore = KnownHostStore()
        self.knownHostStore = knownHostStore
        self.service = CitadelSFTPService(knownHostStore: knownHostStore)
    }

    init(service: SFTPService, knownHostStore: KnownHostStore) {
        self.service = service
        self.knownHostStore = knownHostStore
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
        if let activeTransferJob {
            if activeTransferJob.progressText.isEmpty {
                return activeTransferJob.title
            }
            return "\(activeTransferJob.title) \(activeTransferJob.progressText)"
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

    var selectedItems: [RemoteItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var canDownloadSelection: Bool {
        !selectedItems.isEmpty && !selectedItems.contains { $0.isSymlink }
    }

    var canDeleteSelection: Bool {
        !selectedItems.isEmpty
    }

    var activeTransferJob: TransferJob? {
        transferJobs.first { $0.status == .running }
    }

    var hasFinishedTransfers: Bool {
        transferJobs.contains { $0.isFinished }
    }

    var transferQueueSummary: String {
        let runningCount = transferJobs.filter { $0.status == .running }.count
        let queuedCount = transferJobs.filter { $0.status == .queued }.count
        let failedCount = transferJobs.filter { $0.status == .failed }.count

        var parts: [String] = []
        if runningCount > 0 {
            parts.append("\(runningCount) active")
        }
        if queuedCount > 0 {
            parts.append("\(queuedCount) queued")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) failed")
        }

        return parts.isEmpty ? "Idle" : parts.joined(separator: ", ")
    }

    func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    func quickLookSelection() {
        let selection = selectedItems
        guard selection.count == 1 else {
            errorMessage = selection.isEmpty
                ? "Select a file to preview."
                : "Select one file to preview."
            return
        }

        let item = selection[0]
        guard !item.isDirectory else {
            errorMessage = "Quick Look preview is available for files only."
            return
        }
        guard !item.isSymlink else {
            errorMessage = "Quick Look preview is not available for symlinks. Select the linked target instead."
            return
        }

        let config = connectionConfig()
        let remoteFilePath = remotePath.appendingRemotePathComponent(item.name)
        let totalBytes = item.sizeBytes > 0 ? item.sizeBytes : nil

        startBusyOperation(
            message: "Preparing Preview...",
            canCancel: true,
            showsOverlayAfterDelay: true,
            cancellationMessage: "Preview cancelled."
        ) {
            let localURL = try Self.makeQuickLookPreviewURL(for: item.name)
            let progressHandler = self.transferProgressHandler()
            await progressHandler(TransferProgress(completedBytes: 0, totalBytes: totalBytes))
            try await self.service.downloadFile(
                config: config,
                remoteFilePath: remoteFilePath,
                localURL: localURL,
                progress: progressHandler
            )
            try Task.checkCancellation()
            self.quickLookPreviewController.preview(localURL)
        }
    }

    func connect() {
        startBusyOperation(
            message: "Connecting...",
            canCancel: true,
            showsOverlayAfterDelay: true,
            cancellationMessage: "Connection cancelled."
        ) {
            try await self.connectWithHostKeyHandling()
        }
    }

    func disconnect() {
        cancelAllTransfers()
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
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            upload(panel.urls)
        }
    }

    func upload(_ urls: [URL]) {
        let uploadURLs = urls.filter(Self.isUploadableItem)
        guard !uploadURLs.isEmpty else {
            errorMessage = "Drop one or more files or folders to upload."
            return
        }

        let config = connectionConfig()
        let targetRemotePath = remotePath
        let title = uploadURLs.count == 1 ? "Uploading \(uploadURLs[0].lastPathComponent)" : "Uploading \(uploadURLs.count) items"

        startBusyOperation(
            message: "Checking Upload...",
            canCancel: true,
            showsOverlayAfterDelay: true,
            cancellationMessage: "Upload cancelled."
        ) {
            let conflicts = try await self.service.uploadConflicts(
                config: config,
                localURLs: uploadURLs,
                remoteDirectoryPath: targetRemotePath
            )
            try Task.checkCancellation()
            guard self.confirmReplaceIfNeeded(conflicts, locationDescription: "on the remote server") else {
                return
            }

            self.enqueueTransfer(kind: .upload, title: title, detail: targetRemotePath) { progress in
                try await self.service.uploadItems(
                    config: config,
                    localURLs: uploadURLs,
                    remoteDirectoryPath: targetRemotePath,
                    progress: progress
                )
            } onSuccess: {
                if self.isConnected {
                    try await self.loadCurrentDirectory()
                }
            } onCancel: {
                if self.isConnected {
                    try? await self.loadCurrentDirectory()
                }
            }
        }
    }

    func download() {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        guard !selection.contains(where: \.isSymlink) else {
            errorMessage = "Symlink downloads are not supported yet. Select the linked target instead."
            return
        }

        if selection.count > 1 || selection[0].isDirectory {
            download(selection)
            return
        }

        let selectedItem = selection[0]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedItem.name
        if panel.runModal() == .OK, let url = panel.url {
            let remoteFile = remotePath.appendingRemotePathComponent(selectedItem.name)
            let config = connectionConfig()
            enqueueTransfer(kind: .download, title: "Downloading \(selectedItem.name)", detail: url.deletingLastPathComponent().path) { progress in
                try await self.service.downloadFile(
                    config: config,
                    remoteFilePath: remoteFile,
                    localURL: url,
                    progress: progress
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

    func deleteSelection() {
        let selection = selectedItems
        guard !selection.isEmpty, confirmDelete(selection) else {
            return
        }

        let message = selection.count == 1 ? "Deleting \(selection[0].name)..." : "Deleting \(selection.count) items..."
        let basePath = remotePath
        startBusyOperation(message: message) {
            for item in selection {
                try Task.checkCancellation()
                let itemPath = basePath.appendingRemotePathComponent(item.name)
                try await self.service.deleteItem(config: self.connectionConfig(), remotePath: itemPath, isDirectory: item.isDirectory)
            }
            try await self.loadCurrentDirectory()
        }
    }

    func cancelBusyOperation() {
        guard canCancelBusyOperation, !isCancellingBusyOperation else {
            return
        }

        isCancellingBusyOperation = true
        errorMessage = currentBusyCancellationMessage
        busyOverlayDelayTask?.cancel()
        busyOverlayDelayTask = nil
        isBusy = false
        isBusyOverlayVisible = false
        canCancelBusyOperation = false
        isCancellingBusyOperation = false
        busyMessage = "Working..."
        transferProgress = nil
        transferProgressText = ""
        currentBusyOperationID = nil
        currentBusyTask?.cancel()
        currentBusyTask = nil
        resetTransferTiming()
    }

    func cancelActiveTransfer() {
        guard currentTransferJobID != nil, !isCancellingTransfer else {
            return
        }

        isCancellingTransfer = true
        updateTransferJob(currentTransferJobID) { job in
            job.progressText = "Cancelling..."
        }
        currentTransferTask?.cancel()
    }

    func cancelTransfer(_ id: TransferJob.ID) {
        guard let job = transferJobs.first(where: { $0.id == id }) else {
            return
        }

        switch job.status {
        case .queued:
            queuedTransferOperations.removeAll { $0.id == id }
            finishTransferJob(id, status: .cancelled, errorDescription: nil)
        case .running:
            cancelActiveTransfer()
        case .completed, .failed, .cancelled:
            break
        }
    }

    func clearFinishedTransfers() {
        transferJobs.removeAll { $0.isFinished }
    }

    func filePromiseWriter(for item: RemoteItem) -> RemoteFilePromiseWriter? {
        guard isConnected, !isBusy, !item.isSymlink else {
            return nil
        }

        let promisedRemoteFilePath = remotePath.appendingRemotePathComponent(item.name)
        return RemoteFilePromiseWriter(
            item: item
        ) { [weak self] destinationURL in
            guard let self else {
                throw CancellationError()
            }

            try await self.downloadPromisedItem(
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
        try Task.checkCancellation()
        items = listed
        selectedItemIDs.removeAll()
    }

    private func connectWithHostKeyHandling() async throws {
        do {
            try await connectAndLoadDirectory()
        } catch let hostKeyError as HostKeyValidationError {
            try Task.checkCancellation()
            guard confirmHostKeyTrust(hostKeyError) else {
                throw HostKeyRejectedError()
            }

            try Task.checkCancellation()
            knownHostStore.trust(hostKeyError.presented)
            try await connectAndLoadDirectory()
        }
    }

    private func connectAndLoadDirectory() async throws {
        remotePath = remotePath.normalizedRemotePath()
        let listed = try await service.listDirectory(config: connectionConfig(), path: remotePath)
        try Task.checkCancellation()
        items = listed
        selectedItemIDs.removeAll()
        isConnected = true
    }

    private func download(_ items: [RemoteItem]) {
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

        let config = connectionConfig()
        let sourceRemotePath = remotePath
        let title = items.count == 1 ? "Downloading \(items[0].name)" : "Downloading \(items.count) items"

        startBusyOperation(
            message: "Checking Download...",
            canCancel: true,
            showsOverlayAfterDelay: true,
            cancellationMessage: "Download cancelled."
        ) {
            let conflicts = try await self.service.downloadConflicts(
                config: config,
                remoteItems: items,
                remoteDirectoryPath: sourceRemotePath,
                localDirectoryURL: folderURL
            )
            try Task.checkCancellation()
            guard self.confirmReplaceIfNeeded(conflicts, locationDescription: "in the selected local folder") else {
                return
            }

            self.enqueueTransfer(kind: .download, title: title, detail: folderURL.path) { progress in
                try await self.service.downloadItems(
                    config: config,
                    remoteItems: items,
                    remoteDirectoryPath: sourceRemotePath,
                    localDirectoryURL: folderURL,
                    progress: progress
                )
            }
        }
    }

    private func downloadPromisedItem(item: RemoteItem, remoteFilePath: String, localURL: URL) async throws {
        guard !item.isSymlink else {
            throw AppOperationError.symlinkDownloadUnsupported
        }
        guard !isBusy else {
            throw AppOperationError.busy
        }

        let config = connectionConfig()
        try await withCheckedThrowingContinuation { continuation in
            enqueueTransfer(
                kind: .download,
                title: "Downloading \(item.name)",
                detail: localURL.deletingLastPathComponent().path,
                work: { progress in
                    await progress(TransferProgress(completedBytes: 0, totalBytes: item.sizeBytes > 0 ? item.sizeBytes : nil))
                    if item.isDirectory {
                        try await self.service.downloadItems(
                            config: config,
                            remoteItems: [item],
                            remoteDirectoryPath: remoteFilePath.deletingLastRemotePathComponent(),
                            localDirectoryURL: localURL.deletingLastPathComponent(),
                            progress: progress
                        )
                    } else {
                        try await self.service.downloadFile(
                            config: config,
                            remoteFilePath: remoteFilePath,
                            localURL: localURL,
                            progress: progress
                        )
                    }
                },
                onFinish: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }

    private func enqueueTransfer(
        kind: TransferJob.Kind,
        title: String,
        detail: String,
        work: @escaping @MainActor (_ progress: @escaping TransferProgressHandler) async throws -> Void,
        onSuccess: (@MainActor () async throws -> Void)? = nil,
        onCancel: (@MainActor () async -> Void)? = nil,
        onFinish: (@MainActor (Result<Void, any Error>) -> Void)? = nil
    ) {
        let job = TransferJob(
            kind: kind,
            title: title,
            detail: detail,
            status: .queued,
            progress: nil,
            progressText: "Queued",
            enqueuedAt: Date()
        )
        errorMessage = nil
        transferJobs.append(job)
        queuedTransferOperations.append(
            QueuedTransferOperation(
                id: job.id,
                work: work,
                onSuccess: onSuccess,
                onCancel: onCancel,
                onFinish: onFinish
            )
        )
        startTransferQueueIfNeeded()
    }

    private func startTransferQueueIfNeeded() {
        guard transferQueueTask == nil else {
            return
        }

        transferQueueTask = Task { @MainActor [weak self] in
            await self?.drainTransferQueue()
        }
    }

    private func drainTransferQueue() async {
        while !queuedTransferOperations.isEmpty {
            let operation = queuedTransferOperations.removeFirst()
            guard transferJobs.contains(where: { $0.id == operation.id && $0.status == .queued }) else {
                continue
            }

            currentTransferJobID = operation.id
            isCancellingTransfer = false
            resetTransferTiming()
            transferProgress = nil
            transferProgressText = ""
            updateTransferJob(operation.id) { job in
                job.status = .running
                job.progressText = "Starting..."
                job.startedAt = Date()
            }
            showTransferOverlay(afterDelay: true)

            let transferTask = Task { @MainActor in
                try await operation.work(self.transferProgressHandler(for: operation.id))
            }
            currentTransferTask = transferTask

            do {
                try await transferTask.value
                if let onSuccess = operation.onSuccess {
                    try? await onSuccess()
                }
                finishTransferJob(operation.id, status: .completed, errorDescription: nil)
                operation.onFinish?(.success(()))
            } catch {
                let status: TransferJob.Status = error is CancellationError ? .cancelled : .failed
                let message = status == .cancelled ? nil : userFacingErrorDescription(error)
                finishTransferJob(operation.id, status: status, errorDescription: message)
                if status == .failed {
                    errorMessage = message
                }
                if status == .cancelled {
                    await operation.onCancel?()
                }
                operation.onFinish?(.failure(error))
            }

            currentTransferTask = nil
            currentTransferJobID = nil
            isCancellingTransfer = false
            hideTransferOverlay()
            resetTransferTiming()
        }

        transferQueueTask = nil
        if !queuedTransferOperations.isEmpty {
            startTransferQueueIfNeeded()
        }
    }

    private func finishTransferJob(_ id: TransferJob.ID?, status: TransferJob.Status, errorDescription: String?) {
        updateTransferJob(id) { job in
            job.status = status
            job.errorDescription = errorDescription
            job.completedAt = Date()
            switch status {
            case .completed:
                job.progress = 1
                job.progressText = "Completed"
            case .failed:
                job.progressText = errorDescription ?? "Failed"
            case .cancelled:
                job.progressText = "Cancelled"
            case .queued, .running:
                break
            }
        }
    }

    private func cancelAllTransfers() {
        let queuedIDs = queuedTransferOperations.map(\.id)
        queuedTransferOperations.removeAll()
        for id in queuedIDs {
            finishTransferJob(id, status: .cancelled, errorDescription: nil)
        }
        if currentTransferJobID != nil {
            cancelActiveTransfer()
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
        if item.isSymlink {
            alert.informativeText = "This will delete the selected remote symlink. The linked target will not be deleted."
        } else {
            alert.informativeText = item.isDirectory
                ? "This will recursively delete the selected remote directory and all of its contents."
                : "This will delete the selected remote file."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDelete(_ items: [RemoteItem]) -> Bool {
        guard items.count != 1 else {
            return confirmDelete(items[0])
        }

        let directoryCount = items.filter(\.isDirectory).count
        let symlinkCount = items.filter(\.isSymlink).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(items.count) selected items?"
        if directoryCount > 0 {
            var text = "This will recursively delete the selected remote items, including \(directoryCount) selected folders and all of their contents."
            if symlinkCount > 0 {
                text += " Selected symlinks will be deleted, but their linked targets will not be deleted."
            }
            alert.informativeText = text
        } else if symlinkCount > 0 {
            alert.informativeText = "This will delete the selected remote files and symlinks. Linked targets will not be deleted."
        } else {
            alert.informativeText = "This will delete the selected remote files."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmReplaceIfNeeded(_ names: [String], locationDescription: String) -> Bool {
        let uniqueNames = Array(Set(names)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !uniqueNames.isEmpty else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = uniqueNames.count == 1
            ? "Replace \(uniqueNames[0])?"
            : "Replace \(uniqueNames.count) existing items?"
        alert.informativeText = replaceInformativeText(for: uniqueNames, locationDescription: locationDescription)
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmHostKeyTrust(_ error: HostKeyValidationError) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch error {
        case .unknown(let presented):
            alert.messageText = "Trust Host Key?"
            alert.informativeText = """
            The server at \(presented.host):\(presented.port) is not in your trusted hosts.

            Algorithm: \(presented.algorithm)
            Fingerprint: \(presented.fingerprint)

            Only continue if this fingerprint matches the server you expect.
            """
            alert.addButton(withTitle: "Trust and Connect")

        case .changed(let expected, let presented):
            alert.messageText = "Host Key Changed"
            alert.informativeText = """
            The host key for \(presented.host):\(presented.port) does not match the trusted key.

            Previously trusted: \(expected.fingerprint)
            Presented: \(presented.fingerprint)
            Algorithm: \(presented.algorithm)

            This can indicate a server rebuild or a man-in-the-middle attack. Only continue if you expected this change.
            """
            alert.addButton(withTitle: "Replace and Connect")
        }

        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func replaceInformativeText(for names: [String], locationDescription: String) -> String {
        let visibleNames = names.prefix(8).map { "- \($0)" }.joined(separator: "\n")
        let remainingCount = names.count - 8
        let remainingText = remainingCount > 0 ? "\n- \(remainingCount) more..." : ""

        return """
        The following items already exist \(locationDescription). Replacing them may overwrite their current contents.

        \(visibleNames)\(remainingText)
        """
    }

    private func startBusyOperation(
        message: String = "Working...",
        canCancel: Bool = false,
        showsOverlayAfterDelay: Bool = false,
        cancellationMessage: String = "Operation cancelled.",
        _ work: @escaping () async throws -> Void
    ) {
        guard !isBusy else {
            return
        }

        let operationID = UUID()
        currentBusyOperationID = operationID
        currentBusyCancellationMessage = cancellationMessage

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.runBusy(
                message: message,
                canCancel: canCancel,
                showsOverlayAfterDelay: showsOverlayAfterDelay,
                cancellationMessage: cancellationMessage,
                operationID: operationID,
                work
            )
        }
        currentBusyTask = task
    }

    private func runBusy(
        message: String = "Working...",
        canCancel: Bool = false,
        showsOverlayAfterDelay: Bool = false,
        cancellationMessage: String = "Operation cancelled.",
        operationID: UUID,
        _ work: @escaping () async throws -> Void
    ) async {
        do {
            try await runBusyThrowing(
                message: message,
                canCancel: canCancel,
                showsOverlayAfterDelay: showsOverlayAfterDelay,
                cancellationMessage: cancellationMessage,
                operationID: operationID,
                work
            )
        } catch {
            return
        }
    }

    private func runBusyThrowing(
        message: String = "Working...",
        canCancel: Bool = false,
        showsOverlayAfterDelay: Bool = false,
        cancellationMessage: String = "Operation cancelled.",
        operationID: UUID,
        _ work: @escaping () async throws -> Void
    ) async throws {
        guard currentBusyOperationID == operationID else {
            throw CancellationError()
        }

        errorMessage = nil
        transferProgress = nil
        transferProgressText = ""
        resetTransferTiming()
        busyMessage = message
        isBusy = true
        canCancelBusyOperation = canCancel
        isCancellingBusyOperation = false
        showBusyOverlay(afterDelay: showsOverlayAfterDelay || canCancel)
        defer {
            if currentBusyOperationID == operationID {
                busyOverlayDelayTask?.cancel()
                busyOverlayDelayTask = nil
                isBusy = false
                isBusyOverlayVisible = false
                canCancelBusyOperation = false
                isCancellingBusyOperation = false
                busyMessage = "Working..."
                transferProgress = nil
                transferProgressText = ""
                currentBusyOperationID = nil
                currentBusyTask = nil
                resetTransferTiming()
            }
        }
        do {
            try await work()
        } catch {
            if currentBusyOperationID == operationID {
                if error is CancellationError {
                    errorMessage = cancellationMessage
                } else {
                    errorMessage = userFacingErrorDescription(error)
                }
            }
            throw error
        }
    }

    private func userFacingErrorDescription(_ error: any Error) -> String {
        if let sftpErrorDescription = sftpErrorDescription(error) {
            return sftpErrorDescription
        }

        if error is AuthenticationFailed {
            return authenticationErrorDescription()
        }

        if let sshError = error as? SSHClientError {
            return sshClientErrorDescription(sshError)
        }

        if let citadelError = error as? CitadelError {
            return citadelErrorDescription(citadelError)
        }

        if let connectionError = error as? NIOConnectionError {
            return connectionErrorDescription(connectionError)
        }

        if let channelError = error as? ChannelError {
            return channelErrorDescription(channelError)
        }

        if let ioError = error as? IOError {
            return ioErrorDescription(ioError, host: host, port: port)
        }

        return error.localizedDescription
    }

    private func sftpErrorDescription(_ error: any Error) -> String? {
        if let status = error as? SFTPMessage.Status {
            return sftpStatusDescription(status)
        }

        guard let sftpError = error as? SFTPError else {
            return nil
        }

        switch sftpError {
        case .unknownMessage, .invalidPayload, .invalidResponse:
            return "The SFTP server returned a response this app could not read. Try the operation again."
        case .noResponseTarget, .missingResponse:
            return "The SFTP server did not respond to the request. Try again or reconnect."
        case .connectionClosed:
            return "The SFTP connection was closed. Reconnect and try again."
        case .fileHandleInvalid:
            return "The remote file handle expired. Refresh the folder and try again."
        case .errorStatus(let status):
            return sftpStatusDescription(status)
        case .unsupportedVersion:
            return "The server uses an SFTP version this app does not support."
        }
    }

    private func sftpStatusDescription(_ status: SFTPMessage.Status) -> String {
        let contextPath = remotePath.normalizedRemotePath()
        let serverMessage = serverMessageSuffix(status.message)

        switch status.errorCode {
        case .ok:
            return "The SFTP server reported success, but the operation did not complete.\(serverMessage)"
        case .eof:
            return "The remote path \(contextPath) could not be opened. Check that the folder exists and that you have access.\(serverMessage)"
        case .noSuchFile:
            return "The remote path \(contextPath) does not exist.\(serverMessage)"
        case .permissionDenied:
            return "Permission denied for \(contextPath). Check the account permissions on the server.\(serverMessage)"
        case .failure:
            return "The SFTP server rejected the operation for \(contextPath). Check that the path exists and is accessible.\(serverMessage)"
        case .badMessage:
            return "The SFTP server returned an invalid response. Try again or reconnect.\(serverMessage)"
        case .noConnection:
            return "The SFTP connection is not active. Reconnect and try again.\(serverMessage)"
        case .connectionLost:
            return "The SFTP connection was lost. Reconnect and try again.\(serverMessage)"
        case .unsupportedOperation:
            return "The SFTP server does not support that operation.\(serverMessage)"
        case .unknown(let code):
            return "The SFTP server returned an unknown status code (\(code)).\(serverMessage)"
        }
    }

    private func serverMessageSuffix(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return " Server: \(trimmed)"
    }

    private func authenticationErrorDescription() -> String {
        "Could not sign in. Check the username and password for \(host.trimmingCharacters(in: .whitespacesAndNewlines))."
    }

    private func sshClientErrorDescription(_ error: SSHClientError) -> String {
        switch error {
        case .unsupportedPasswordAuthentication:
            return "This server does not allow password authentication. Enable password login on the server or use a different server."
        case .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
            return "This server requires an authentication method this app does not support yet."
        case .channelCreationFailed:
            return "Connected to the server, but could not open an SFTP channel."
        case .allAuthenticationOptionsFailed:
            return authenticationErrorDescription()
        }
    }

    private func citadelErrorDescription(_ error: CitadelError) -> String {
        switch error {
        case .unauthorized:
            return authenticationErrorDescription()
        case .channelCreationFailed, .channelFailure:
            return "Connected to the server, but the SFTP channel failed. Check that SFTP is enabled for this account."
        case .unsupported:
            return "The server requested an SSH/SFTP feature this app does not support."
        case .cryptographicError, .invalidMac, .invalidSignature, .signingError:
            return "The SSH connection failed during encryption setup. Reconnect and verify the server is trusted."
        default:
            return "The SSH connection failed. \(error.localizedDescription)"
        }
    }

    private func connectionErrorDescription(_ error: NIOConnectionError) -> String {
        if error.dnsAError != nil || error.dnsAAAAError != nil {
            return "Could not resolve \(error.host). Check the host name or DNS/VPN connection."
        }

        let ioErrors = error.connectionErrors.compactMap { $0.error as? IOError }
        if let ioError = ioErrors.first {
            return ioErrorDescription(ioError, host: error.host, port: error.port)
        }

        return "Could not connect to \(error.host):\(error.port). Check the host, port, network, VPN, and firewall."
    }

    private func channelErrorDescription(_ error: ChannelError) -> String {
        let target = "\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"

        switch error {
        case .connectPending:
            return "A connection to \(target) is already in progress."
        case .connectTimeout:
            return "Connection to \(target) timed out. Check the host, port, network, VPN, firewall, or server status."
        case .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed, .eof:
            return "The connection to \(target) closed before SFTP could start. Check the host, port, network, VPN, and server status."
        case .writeHostUnreachable:
            return "Host \(host.trimmingCharacters(in: .whitespacesAndNewlines)) is unreachable. Check the host name, network, or VPN connection."
        case .operationUnsupported, .inappropriateOperationForState:
            return "The network connection could not be opened. Check the host, port, and server configuration."
        default:
            return "Could not connect to \(target). Check the host, port, network, VPN, and server status."
        }
    }

    private func ioErrorDescription(_ error: IOError, host: String, port: Int) -> String {
        switch error.errnoCode {
        case ECONNREFUSED:
            return "Connection refused by \(host):\(port). The server is reachable, but SSH/SFTP is not accepting connections on that port."
        case ETIMEDOUT:
            return "Connection to \(host):\(port) timed out. Check the network, VPN, firewall, or server status."
        case EHOSTUNREACH:
            return "Host \(host) is unreachable. Check the network, VPN, or server address."
        case ENETUNREACH:
            return "Network is unreachable. Check your network or VPN connection."
        case ECONNRESET:
            return "Connection to \(host):\(port) was reset by the server."
        default:
            return "Could not connect to \(host):\(port). \(error.localizedDescription)"
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
            try? await Task.sleep(for: .seconds(Self.busyOverlayDelay))
            guard let self, !Task.isCancelled, self.isBusy else {
                return
            }

            self.isBusyOverlayVisible = true
        }
    }

    private func transferProgressHandler(for jobID: TransferJob.ID? = nil) -> TransferProgressHandler {
        { [weak self] progress in
            await self?.updateTransferProgress(progress, for: jobID)
        }
    }

    private func updateTransferProgress(_ progress: TransferProgress, for jobID: TransferJob.ID? = nil) {
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
            updateTransferJob(jobID) { job in
                job.progress = fraction
                job.progressText = self.transferProgressText
            }
        } else {
            transferProgress = nil
            transferProgressText = "\(Self.byteCountFormatter.string(fromByteCount: progress.completedBytes)) transferred"
            updateTransferJob(jobID) { job in
                job.progress = nil
                job.progressText = self.transferProgressText
            }
        }
    }

    private func updateTransferJob(_ id: TransferJob.ID?, update: (inout TransferJob) -> Void) {
        guard let id, let index = transferJobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        update(&transferJobs[index])
    }

    private func showTransferOverlay(afterDelay: Bool) {
        transferOverlayDelayTask?.cancel()
        isTransferOverlayVisible = false

        guard afterDelay else {
            isTransferOverlayVisible = true
            return
        }

        transferOverlayDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.transferOverlayDelay))
            guard let self, !Task.isCancelled, self.activeTransferJob != nil else {
                return
            }

            self.isTransferOverlayVisible = true
        }
    }

    private func hideTransferOverlay() {
        transferOverlayDelayTask?.cancel()
        transferOverlayDelayTask = nil
        isTransferOverlayVisible = false
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
    private static let busyOverlayDelay = 0.75
    private static let transferOverlayDelay = 1.5

    private static var quickLookCacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SFTP-Browser-QuickLook", isDirectory: true)
    }

    private static func makeQuickLookPreviewURL(for fileName: String) throws -> URL {
        let directory = quickLookCacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private static func isUploadableItem(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return false
        }
        return values?.isRegularFile == true || values?.isDirectory == true
    }
}

@MainActor
private final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource {
    private var previewURL: URL?

    func preview(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else {
            return
        }

        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL.map { $0 as NSURL }
    }
}

private enum AppOperationError: LocalizedError {
    case busy
    case symlinkDownloadUnsupported

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another operation is already running."
        case .symlinkDownloadUnsupported:
            return "Symlink downloads are not supported yet. Select the linked target instead."
        }
    }
}

struct TransferJob: Identifiable, Equatable {
    enum Kind: Equatable {
        case upload
        case download

        var systemImage: String {
            switch self {
            case .upload:
                return "square.and.arrow.up"
            case .download:
                return "square.and.arrow.down"
            }
        }
    }

    enum Status: Equatable {
        case queued
        case running
        case completed
        case failed
        case cancelled

        var label: String {
            switch self {
            case .queued:
                return "Queued"
            case .running:
                return "Running"
            case .completed:
                return "Done"
            case .failed:
                return "Failed"
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    var status: Status
    var progress: Double?
    var progressText: String
    let enqueuedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var errorDescription: String?

    var isFinished: Bool {
        switch status {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running:
            return false
        }
    }
}

private struct QueuedTransferOperation {
    let id: TransferJob.ID
    let work: @MainActor (_ progress: @escaping TransferProgressHandler) async throws -> Void
    let onSuccess: (@MainActor () async throws -> Void)?
    let onCancel: (@MainActor () async -> Void)?
    let onFinish: (@MainActor (Result<Void, any Error>) -> Void)?
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
