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
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
    }
}
