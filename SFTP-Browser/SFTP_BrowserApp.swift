//
//  SFTP_BrowserApp.swift
//  SFTP-Browser
//
//  Created by George Babichev on 1/18/26.
//

import SwiftUI

@main
struct SFTP_BrowserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }
}
