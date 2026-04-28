//
//  TrustedHostsView.swift
//  SFTP-Browser
//
//  Created by OpenAI on 4/27/26.
//

import SwiftUI

struct TrustedHostsView: View {
    let store: KnownHostStore
    let onClose: () -> Void

    @State private var hosts: [HostKeyDetails] = []
    @State private var selectedHostID: HostKeyDetails.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 380)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Text("Trusted Hosts")
                .font(.headline)
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if hosts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "shield")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No Trusted Hosts")
                    .font(.headline)
                Text("Host keys you trust during connection will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedHostID) {
                ForEach(hosts, id: \.id) { host in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(host.host):\(host.port)")
                                .font(.headline)
                            Spacer()
                            Text(host.algorithm)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(host.fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Trusted \(host.trustedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .tag(host.id)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                removeSelectedHost()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selectedHost == nil)

            Spacer()

            Button("Done") {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var selectedHost: HostKeyDetails? {
        hosts.first { $0.id == selectedHostID }
    }

    private func reload() {
        hosts = store.trustedHosts()
        if selectedHostID != nil, selectedHost == nil {
            selectedHostID = nil
        }
    }

    private func removeSelectedHost() {
        guard let selectedHost else {
            return
        }

        store.remove(selectedHost)
        selectedHostID = nil
        reload()
    }
}
