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
    @StateObject private var model = StackViewModel()

    var body: some Scene {
        Window("Queries", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CheckForUpdatesCommands(updater: updater)
            CommandGroup(replacing: .newItem) {
                Button("New Query…") { model.editing = SavedQuery() }.keyboardShortcut("n")
                Divider()
                Button("Import Collection…") { model.showImporter = true }
                Button("Export Collection…") { model.showExporter = true }
            }
            CommandGroup(after: .toolbar) {
                Button("Collapse All") { withAnimation(.snappy(duration: 0.2)) { model.collapseAll() } }
                    .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(model.collection.queries.isEmpty)
                Button("Expand All") { withAnimation(.snappy(duration: 0.2)) { model.expandAll() } }
                    .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(model.collection.queries.isEmpty)
            }
            CommandMenu("Query") {
                Button("Refresh All") { model.refreshAll() }.keyboardShortcut("r")
            }
        }
        Settings {
            SetupView(model: model)
        }
    }
}
