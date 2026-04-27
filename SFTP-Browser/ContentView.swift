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
        VStack(spacing: 12) {
            connectionPanel
            browserPanel
            statusPanel
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Host", text: $viewModel.host)
                TextField("Port", value: $viewModel.port, format: .number)
                    .frame(width: 80)
                TextField("Username", text: $viewModel.username)
                SecureField("Password", text: $viewModel.password)
            }
            HStack(spacing: 8) {
                TextField("Remote Path", text: $viewModel.remotePath)
                Spacer()
                Button(viewModel.isConnected ? "Disconnect" : "Connect") {
                    viewModel.toggleConnection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canConnect)
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
                Button {
                    viewModel.goUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Up")
                .disabled(!viewModel.isConnected || viewModel.isBusy)
                Button("Refresh") {
                    viewModel.refresh()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)
                Button("Upload") {
                    viewModel.upload()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)
                Button("Download") {
                    viewModel.download()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy || viewModel.selectedItem?.isDirectory != false)
            }
            List(selection: $viewModel.selectedItem) {
                ForEach(viewModel.items) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                        Text(item.name)
                        Spacer()
                        if !item.isDirectory {
                            Text(item.sizeDescription)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .tag(item)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.open(item)
                    }
                }
            }
        }
    }

    private var statusPanel: some View {
        HStack {
            if viewModel.isBusy {
                ProgressView()
            }
            Text(viewModel.statusText)
                .foregroundColor(viewModel.errorMessage == nil ? Color.secondary : Color.red)
            Spacer()
        }
        .frame(height: 20)
    }
}

#Preview {
    ContentView()
}
