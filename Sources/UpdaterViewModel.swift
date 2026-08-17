import Combine
import Sparkle
import SwiftUI

/// Bridges `SPUUpdater`'s KVO-driven and persisted state into SwiftUI. Sparkle persists the automatic
/// check/download preferences in the app's defaults domain itself, so they are not mirrored into
/// custom keys.
@MainActor
final class UpdaterViewModel: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// Menu item that triggers a manual update check, disabled while Sparkle is mid-check.
struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") {
            viewModel.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Settings section exposing Sparkle's automatic-update preferences and last-check time.
struct UpdatesSectionView: View {
    @ObservedObject var viewModel: UpdaterViewModel

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { viewModel.automaticallyChecksForUpdates },
                set: { viewModel.automaticallyChecksForUpdates = $0 }
            ))
            Toggle("Automatically download updates", isOn: Binding(
                get: { viewModel.automaticallyDownloadsUpdates },
                set: { viewModel.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!viewModel.automaticallyChecksForUpdates)

            if let lastCheck = viewModel.lastUpdateCheckDate {
                Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
