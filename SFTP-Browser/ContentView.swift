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
    @AppStorage("connection.remotePath") private var storedRemotePath = "."

    private let passwordStore = KeychainPasswordStore()

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
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.toggleConnection()
                } label: {
                    Label(
                        viewModel.isConnected ? "Disconnect" : "Connect",
                        systemImage: viewModel.isConnected ? "bolt.slash" : "bolt"
                    )
                }
                .disabled(!viewModel.canConnect)

                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)
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
            passwordStore.savePassword(password)
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
        viewModel.host = storedHost
        viewModel.port = storedPort
        viewModel.username = storedUsername
        viewModel.remotePath = storedRemotePath
        viewModel.password = passwordStore.loadPassword()
    }
}

#Preview {
    ContentView()
}
