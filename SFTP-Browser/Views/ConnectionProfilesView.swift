//
//  ConnectionProfilesView.swift
//  SFTP-Browser
//
//  Created by OpenAI on 4/27/26.
//

import SwiftUI

struct ConnectionProfilesView: View {
    let profiles: [ConnectionProfile]
    let canSaveProfile: Bool
    let canUseProfile: Bool
    let onSave: () -> Void
    let onUse: (ConnectionProfile) -> Void
    let onDelete: (ConnectionProfile) -> Void
    let onClose: () -> Void

    @State private var selectedProfileID: ConnectionProfile.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 360)
    }

    private var header: some View {
        HStack {
            Text("Connection Profiles")
                .font(.headline)
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if profiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No Profiles")
                    .font(.headline)
                Text("Save the current connection to create a reusable profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName)
                            .font(.headline)
                        Text(profile.detailText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(profile.id)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                onSave()
            } label: {
                Label("Save Current", systemImage: "plus")
            }
            .disabled(!canSaveProfile)

            Button(role: .destructive) {
                if let selectedProfile {
                    onDelete(selectedProfile)
                    selectedProfileID = nil
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedProfile == nil)

            Spacer()

            Button("Use") {
                if let selectedProfile {
                    onUse(selectedProfile)
                }
            }
            .disabled(selectedProfile == nil || !canUseProfile)

            Button("Done") {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }
}
