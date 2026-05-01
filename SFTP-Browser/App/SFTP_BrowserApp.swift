//
//  SFTP_BrowserApp.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import AppKit
import Combine
import SwiftUI

@main
struct SFTP_BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var aboutController = AboutOverlayController()
    @StateObject private var updateCenter = AppUpdateCenter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(aboutController)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .commands {
            SFTPBrowserCommands(
                aboutController: aboutController,
                updateCenter: updateCenter
            )
        }
    }
}

private struct SFTPBrowserCommands: Commands {
    @ObservedObject var aboutController: AboutOverlayController
    @ObservedObject var updateCenter: AppUpdateCenter
    @FocusedValue(\.sftpBrowserCommandContext) private var browserCommandContext

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                aboutController.present()
            } label: {
                Label("About SFTP Browser", systemImage: "info.circle")
            }

            Button {
                updateCenter.checkForUpdates(trigger: .manual)
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .disabled(updateCenter.isChecking)
        }

        CommandGroup(replacing: .newItem) {
            Button {
                browserCommandContext?.newFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(browserCommandContext?.canCreateFolder != true)
        }

        CommandMenu("Remote") {
            Button {
                browserCommandContext?.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(browserCommandContext?.canRefresh != true)

            Button {
                browserCommandContext?.upload()
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(browserCommandContext?.canUpload != true)

            Button {
                browserCommandContext?.download()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(browserCommandContext?.canDownload != true)

            Divider()

            Button(role: .destructive) {
                browserCommandContext?.deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(browserCommandContext?.canDelete != true)
        }

        CommandMenu("Tools") {
            Button {
                browserCommandContext?.cleanDSStoreFiles()
            } label: {
                Label("Clean Up .DS_Store", systemImage: "sparkles")
            }
            .disabled(browserCommandContext?.canCleanDSStoreFiles != true)
        }
    }
}

struct SFTPBrowserCommandContext {
    let canRefresh: Bool
    let canCreateFolder: Bool
    let canUpload: Bool
    let canDownload: Bool
    let canDelete: Bool
    let canCleanDSStoreFiles: Bool
    let refresh: () -> Void
    let newFolder: () -> Void
    let upload: () -> Void
    let download: () -> Void
    let deleteSelection: () -> Void
    let cleanDSStoreFiles: () -> Void
}

private struct SFTPBrowserCommandContextKey: FocusedValueKey {
    typealias Value = SFTPBrowserCommandContext
}

extension FocusedValues {
    var sftpBrowserCommandContext: SFTPBrowserCommandContext? {
        get { self[SFTPBrowserCommandContextKey.self] }
        set { self[SFTPBrowserCommandContextKey.self] = newValue }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
    }
}
