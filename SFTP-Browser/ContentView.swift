//
//  ContentView.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @AppStorage("connection.host") private var storedHost = ""
    @AppStorage("connection.port") private var storedPort = 22
    @AppStorage("connection.username") private var storedUsername = ""
    @AppStorage("connection.remotePath") private var storedRemotePath = "/"

    @State private var profiles: [ConnectionProfile] = []
    @State private var selectedProfileID: ConnectionProfile.ID?
    @State private var isProfilesPresented = false
    @State private var isTrustedHostsPresented = false

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
            if viewModel.isBusyOverlayVisible {
                busyOverlay
            }
        }
        .toolbar {
            ToolbarItemGroup {
                connectionMenu
            }

//            ToolbarSpacer(.fixed, placement: .automatic)
            
            ToolbarItemGroup {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)
                
                Button {
                    viewModel.createFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

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
        ZStack {
            Color.black.opacity(0.08)
            VStack(spacing: 12) {
                if let transferProgress = viewModel.transferProgress {
                    ProgressView(value: transferProgress)
                        .frame(width: 240)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(viewModel.busyMessage)
                    .font(.headline)
                if !viewModel.transferProgressText.isEmpty {
                    Text(viewModel.transferProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Please wait until the current operation finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.canCancelBusyOperation {
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
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                TextField("Host", text: $viewModel.host)
                TextField("Port", value: $viewModel.port, format: .number)
                    .frame(width: 80)
                TextField("Username", text: $viewModel.username)
                SecureField("Password", text: $viewModel.password)
                    .onSubmit {
                        if !viewModel.isConnected, viewModel.canConnect {
                            viewModel.connect()
                        }
                    }
            }

            GridRow {
                HStack(spacing: 8) {
                    TextField("Remote Path", text: $viewModel.remotePath)
                        .onSubmit {
                            viewModel.submitRemotePath()
                        }

                    Button {
                        viewModel.goUp()
                    } label: {
                        Label("Parent Folder", systemImage: "arrow.up")
                    }
                    .labelStyle(.iconOnly)
                    .help("Parent Folder")
                    .disabled(!viewModel.isConnected || viewModel.isBusy)
                }
                .gridCellColumns(4)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var browserPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote Files")
                    .font(.headline)
                Spacer()
            }
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
            HStack(spacing: 8) {
                if viewModel.isBusy {
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

#Preview {
    ContentView()
}
