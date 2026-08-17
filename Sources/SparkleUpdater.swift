import Sparkle
import SwiftUI

/// Owns Sparkle's updater controller and starts it only in a real, feed-configured Release bundle, so
/// debug builds and unit tests never spin up scheduled update checks. The updater is created stopped
/// and started manually once the app has launched.
@MainActor
final class PolluxAppDelegate: NSObject, NSApplicationDelegate {
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    lazy var updaterViewModel = UpdaterViewModel(updater: updaterController.updater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only start Sparkle in a release build that carries an update feed. `swift`/xctest runs and
        // local debug builds have no `SUFeedURL`, so the updater stays inert there.
        #if !DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController.startUpdater()
        }
        #endif
    }
}
