import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    #if DEBUG
    private static let startsAutomatically = false
    #else
    private static let startsAutomatically = true
    #endif

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: AppUpdater.startsAutomatically,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

struct CheckForUpdatesCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
