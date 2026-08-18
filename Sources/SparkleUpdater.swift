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

    /// Retained GCD signal sources for SIGTERM/SIGINT/SIGHUP. AppKit's `applicationWillTerminate` covers a
    /// graceful quit (Command+Q, menu Quit), but a terminal `pkill`/Ctrl+C or a logout/shutdown arrives as
    /// a POSIX signal that never posts that notification — leaving an orphaned, silent Chromium behind.
    /// These sources reap the browser tree on any such signal before exiting.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()

        // Only start Sparkle in a release build that carries an update feed. `swift`/xctest runs and
        // local debug builds have no `SUFeedURL`, so the updater stays inert there.
        #if !DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController.startUpdater()
        }
        #endif
    }

    /// Graceful-quit path (Command+Q, menu Quit, logout with sudden termination disabled): synchronously
    /// tear down every Chromium the app launched so none survive as a background zombie.
    func applicationWillTerminate(_ notification: Notification) {
        ChromiumProcessTracker.shared.terminateAll()
    }

    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            // Ignore the default disposition so the process isn't summarily killed before our handler
            // runs; the DispatchSource below (which fires on a normal queue, not in signal-handler
            // context, so it may safely call our teardown) takes over.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                ChromiumProcessTracker.shared.terminateAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
