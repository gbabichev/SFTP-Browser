//
//  ContentView.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

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
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canConnect)

                Button {
                    viewModel.goUp()
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

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
    }

    private var connectionPanel: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                TextField("Host", text: $viewModel.host)
                TextField("Port", value: $viewModel.port, format: .number)
                    .frame(width: 80)
                TextField("Username", text: $viewModel.username)
                SecureField("Password", text: $viewModel.password)
            }

            GridRow {
                TextField("Remote Path", text: $viewModel.remotePath)
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
}

#Preview {
    ContentView()
}
