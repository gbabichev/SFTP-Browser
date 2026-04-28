//
//  ContentView.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var aboutController: AboutOverlayController
    @StateObject private var viewModel = AppViewModel()
    @AppStorage("connection.host") private var storedHost = ""
    @AppStorage("connection.port") private var storedPort = 22
    @AppStorage("connection.username") private var storedUsername = ""
    @AppStorage("connection.remotePath") private var storedRemotePath = "/"

    @State private var profiles: [ConnectionProfile] = []
    @State private var selectedProfileID: ConnectionProfile.ID?
    @State private var isProfilesPresented = false
    @State private var isTrustedHostsPresented = false
    @State private var isPasswordVisible = false

    private let profileStore = ConnectionProfileStore()
    private let knownHostStore = KnownHostStore()

    var body: some View {
        VStack(spacing: 0) {
            connectionPanel
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 12)
            browserPanel
                .padding(.horizontal, 16)
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay {
            if viewModel.isBusyOverlayVisible || viewModel.isTransferOverlayVisible {
                busyOverlay
            }
        }
        .overlay {
            if aboutController.isPresented {
                AboutOverlayView(isPresented: $aboutController.isPresented)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                connectionMenu
            }

            ToolbarItemGroup {
                Button {
                    viewModel.upload()
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button {
                    viewModel.download()
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy || !viewModel.canDownloadSelection)
            }
        }
        .sheet(isPresented: $isProfilesPresented) {
            ConnectionProfilesView(
                profiles: profiles,
                canSaveProfile: viewModel.canConnect,
                canUseProfile: !viewModel.isConnected && !viewModel.isBusy,
                onSave: {
                    saveCurrentProfile()
                },
                onUse: { profile in
                    apply(profile)
                    isProfilesPresented = false
                },
                onDelete: { profile in
                    delete(profile)
                },
                onClose: {
                    isProfilesPresented = false
                }
            )
        }
        .sheet(isPresented: $isTrustedHostsPresented) {
            TrustedHostsView(
                store: knownHostStore,
                onClose: {
                    isTrustedHostsPresented = false
                }
            )
        }
        .onAppear(perform: restoreStoredConnection)
        .onChange(of: viewModel.host) { _, host in
            storedHost = host
        }
        .onChange(of: viewModel.port) { _, port in
            storedPort = port
        }
        .onChange(of: viewModel.username) { _, username in
            storedUsername = username
        }
        .onChange(of: viewModel.remotePath) { _, remotePath in
            storedRemotePath = remotePath
        }
        .onChange(of: viewModel.password) { _, password in
            passwordStore().savePassword(password)
        }
    }

    private var busyOverlay: some View {
        let activeTransferJob = viewModel.activeTransferJob
        let progress = activeTransferJob?.progress ?? viewModel.transferProgress
        let message = activeTransferJob?.title ?? viewModel.busyMessage
        let progressText = activeTransferJob?.progressText ?? viewModel.transferProgressText

        return ZStack {
            Color.black.opacity(0.08)
            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 240)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(message)
                    .font(.headline)
                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(activeTransferJob == nil ? "Please wait until the current operation finishes." : "Transfers run one at a time. Queued transfers start automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if activeTransferJob != nil {
                    Button(role: .cancel) {
                        viewModel.cancelActiveTransfer()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isCancellingTransfer)
                } else if viewModel.canCancelBusyOperation {
                    Button(role: .cancel) {
                        viewModel.cancelBusyOperation()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isCancellingBusyOperation)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 12, y: 4)
        }
        .ignoresSafeArea()
    }

    private var connectionMenu: some View {
        Menu {
            if profiles.isEmpty {
                Text("No Profiles")
            } else {
                ForEach(profiles) { profile in
                    Button {
                        connect(using: profile)
                    } label: {
                        Label(profile.displayName, systemImage: "person.crop.rectangle")
                    }
                    .disabled(viewModel.isConnected || viewModel.isBusy)
                }
            }

            Divider()

            Button {
                isProfilesPresented = true
            } label: {
                Label("Manage Profiles", systemImage: "person.crop.rectangle.stack")
            }

            Button {
                isTrustedHostsPresented = true
            } label: {
                Label("Trusted Hosts", systemImage: "shield")
            }
        } label: {
            Label(
                viewModel.isConnected ? "Disconnect" : "Connect",
                systemImage: viewModel.isConnected ? "bolt.slash" : "bolt"
            )
        } primaryAction: {
            if viewModel.canConnect {
                viewModel.toggleConnection()
            }
        }
    }

    private var connectionPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                TextField("Host", text: $viewModel.host)
                    .frame(minWidth: 160)

                TextField("Port", value: $viewModel.port, format: .number)
                    .frame(width: 68)

                Divider()
                    .frame(height: 18)

                Image(systemName: "person")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                TextField("Username", text: $viewModel.username)
                    .frame(minWidth: 130)

                HStack(spacing: 4) {
                    Group {
                        if isPasswordVisible {
                            TextField("Password", text: $viewModel.password)
                        } else {
                            SecureField("Password", text: $viewModel.password)
                        }
                    }
                    .onSubmit {
                        if !viewModel.isConnected, viewModel.canConnect {
                            viewModel.connect()
                        }
                    }

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isPasswordVisible ? "Hide Password" : "Show Password")
                    .accessibilityLabel(isPasswordVisible ? "Hide Password" : "Show Password")
                }
                .frame(minWidth: 150)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("Remote Files")
                    .font(.headline)

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    TextField("Remote Path", text: $viewModel.remotePath)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            viewModel.submitRemotePath()
                        }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                )
                .frame(maxWidth: .infinity)

                Button {
                    viewModel.goUp()
                } label: {
                    Label("Parent Folder", systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .help("Parent Folder")
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh")
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button {
                    viewModel.createFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
                .help("New Folder")
                .disabled(!viewModel.isConnected || viewModel.isBusy)
            }
            .controlSize(.small)
        }
    }

    private var browserPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteFileTableView(
                items: viewModel.items,
                selectedItemIDs: $viewModel.selectedItemIDs,
                actionsEnabled: viewModel.isConnected && !viewModel.isBusy,
                onOpen: { item in
                    viewModel.open(item)
                },
                onRename: { item in
                    viewModel.rename(item)
                },
                onDelete: { item in
                    viewModel.delete(item)
                },
                onCreateFolder: {
                    viewModel.createFolder()
                },
                onUpload: { urls in
                    viewModel.upload(urls)
                },
                makeFilePromiseWriter: { item in
                    viewModel.filePromiseWriter(for: item)
                }
            )
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            if !viewModel.transferJobs.isEmpty {
                TransferQueueFooter(
                    jobs: viewModel.transferJobs,
                    summary: viewModel.transferQueueSummary,
                    hasFinishedTransfers: viewModel.hasFinishedTransfers,
                    onCancel: { id in
                        viewModel.cancelTransfer(id)
                    },
                    onClearFinished: {
                        viewModel.clearFinishedTransfers()
                    }
                )
                Divider()
            }
            HStack(spacing: 8) {
                if viewModel.isBusy || viewModel.activeTransferJob != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundColor(viewModel.errorMessage == nil ? Color.secondary : Color.red)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func restoreStoredConnection() {
        reloadProfiles()
        viewModel.host = storedHost
        viewModel.port = storedPort
        viewModel.username = storedUsername
        viewModel.remotePath = storedRemotePath == "." ? "/" : storedRemotePath
        selectedProfileID = matchingProfileID()
        viewModel.password = loadCurrentPassword()
    }

    private func apply(_ profile: ConnectionProfile) {
        viewModel.host = profile.host
        viewModel.port = profile.port
        viewModel.username = profile.username
        viewModel.remotePath = profile.remotePath == "." ? "/" : profile.remotePath
        selectedProfileID = profile.id
        viewModel.password = loadPassword(for: profile)
    }

    private func connect(using profile: ConnectionProfile) {
        apply(profile)
        if viewModel.canConnect {
            viewModel.connect()
        }
    }

    private func saveCurrentProfile() {
        guard let name = promptForProfileName() else {
            return
        }

        let now = Date()
        let profile = ConnectionProfile(
            id: selectedProfileID ?? UUID(),
            name: name,
            host: viewModel.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: viewModel.port,
            username: viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePath: normalizedRemotePath(viewModel.remotePath),
            updatedAt: now
        )

        profileStore.save(profile)
        selectedProfileID = profile.id
        passwordStore(for: profile).savePassword(viewModel.password)
        reloadProfiles()
    }

    private func delete(_ profile: ConnectionProfile) {
        profileStore.delete(profile)
        passwordStore(for: profile).deletePassword()
        if selectedProfileID == profile.id {
            selectedProfileID = nil
        }
        reloadProfiles()
    }

    private func reloadProfiles() {
        profiles = profileStore.profiles()
        if selectedProfileID != nil, profiles.first(where: { $0.id == selectedProfileID }) == nil {
            selectedProfileID = nil
        }
    }

    private func matchingProfileID() -> ConnectionProfile.ID? {
        profiles.first { profile in
            profile.host.caseInsensitiveCompare(viewModel.host.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && profile.port == viewModel.port
            && profile.username == viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines)
            && normalizedRemotePath(profile.remotePath) == normalizedRemotePath(viewModel.remotePath)
        }?.id
    }

    private func promptForProfileName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Connection Profile"
        alert.informativeText = "Enter a name for this connection profile."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let defaultName = profiles.first(where: { $0.id == selectedProfileID })?.name
            ?? "\(viewModel.username)@\(viewModel.host)"
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = defaultName
        textField.selectText(nil)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultName : name
    }

    private func passwordStore() -> KeychainPasswordStore {
        KeychainPasswordStore(account: passwordAccount(
            host: viewModel.host,
            port: viewModel.port,
            username: viewModel.username
        ))
    }

    private func passwordStore(for profile: ConnectionProfile) -> KeychainPasswordStore {
        KeychainPasswordStore(account: passwordAccount(
            host: profile.host,
            port: profile.port,
            username: profile.username
        ))
    }

    private func loadCurrentPassword() -> String {
        let scopedPassword = passwordStore().loadPassword()
        return scopedPassword.isEmpty ? KeychainPasswordStore().loadPassword() : scopedPassword
    }

    private func loadPassword(for profile: ConnectionProfile) -> String {
        let scopedPassword = passwordStore(for: profile).loadPassword()
        return scopedPassword.isEmpty ? KeychainPasswordStore().loadPassword() : scopedPassword
    }

    private func passwordAccount(host: String, port: Int, username: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "sftp-password:\(normalizedUsername)@\(normalizedHost):\(port)"
    }

    private func normalizedRemotePath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            return "/"
        }
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

private struct TransferQueueFooter: View {
    let jobs: [TransferJob]
    let summary: String
    let hasFinishedTransfers: Bool
    let onCancel: (TransferJob.ID) -> Void
    let onClearFinished: () -> Void

    private var visibleJobs: [TransferJob] {
        let runningJobs = jobs.filter { $0.status == .running }
        let otherJobs = jobs.filter { $0.status != .running }
        let remainingSlots = max(0, 4 - runningJobs.count)
        return runningJobs + Array(otherJobs.suffix(remainingSlots))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasFinishedTransfers {
                    Button {
                        onClearFinished()
                    } label: {
                        Label("Clear Finished", systemImage: "checkmark.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Clear Finished Transfers")
                }
            }

            ForEach(visibleJobs) { job in
                TransferQueueRow(job: job, onCancel: onCancel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct TransferQueueRow: View {
    let job: TransferJob
    let onCancel: (TransferJob.ID) -> Void

    private var canCancel: Bool {
        job.status == .queued || job.status == .running
    }

    private var statusColor: Color {
        switch job.status {
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case .completed:
            return .green
        case .queued, .running:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: job.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.status.label)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }

                HStack(spacing: 8) {
                    if job.status == .running {
                        if let progress = job.progress {
                            ProgressView(value: progress)
                                .frame(width: 120)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 120)
                        }
                    } else if job.status == .queued {
                        ProgressView(value: 0)
                            .frame(width: 120)
                    }

                    Text(job.progressText.isEmpty ? job.detail : job.progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if canCancel {
                Button(role: .cancel) {
                    onCancel(job.id)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Cancel Transfer")
            }
        }
    }
}

#Preview {
    ContentView()
}
