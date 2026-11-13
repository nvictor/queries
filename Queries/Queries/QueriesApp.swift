//
//  QueriesApp.swift
//  Queries
//
//  Created by Victor Noagbodji on 11/12/26.
//

import SwiftUI

@main
struct QueriesApp: App {
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("Queries", id: "main") {
            ContentView()
        }
        .commands {
            CheckForUpdatesCommands(updater: updater)
        }
    }
}
