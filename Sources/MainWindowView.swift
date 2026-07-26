import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @Environment(\.openWindow) private var openWindow

    /// Optional window seed. When it carries a URL (e.g. from Open Recent) the window auto-plays it.
    let request: StreamRequest?

    @State private var urlText: String = ""
    @State private var didSeed = false

    init(request: StreamRequest? = nil) {
        self.request = request
    }

    var body: some View {
        Group {
            if let permissionIssue = model.permissionIssue {
                PermissionsRequiredView(issue: permissionIssue)
            } else {
                streamControls
            }
        }
        .onAppear {
            seedIfNeeded()
            Task {
                await model.runStartupPermissionCheckIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: model.lastError) { _, newValue in
            // Surface errors in a dedicated window rather than inline in the main window.
            if newValue != nil {
                openWindow(id: PolluxAppModel.errorWindowID)
            }
        }
    }

    private var streamControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Player Page URL")
                    .font(.headline)

                TextField("https://example.com/watch/...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(startPlayback)
                    .disabled(model.isExtracting)

                if model.isExtracting {
                    extractionProgress
                }

                HStack(spacing: 12) {
                    primaryButton

                    if model.player != nil {
                        Button("Open Player Window") {
                            openWindow(id: PolluxAppModel.playerWindowID)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 500, minHeight: 155)
    }

    private var extractionProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: model.extractionProgress)
                .progressViewStyle(.linear)

            HStack {
                Text(model.extractionPhase.isEmpty ? "Extracting stream…" : model.extractionPhase)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(model.extractionProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var primaryButton: some View {
        if model.isExtracting {
            Button(role: .destructive) {
                model.cancelExtraction()
            } label: {
                Label("Stop Extracting", systemImage: "stop.fill")
            }
        } else if model.player != nil {
            // While a stream is playing, the Play button becomes a Stop button (no separate control).
            Button(role: .destructive) {
                model.stopPlayback()
            } label: {
                Label("Stop Stream", systemImage: "stop.fill")
            }
        } else {
            Button(action: startPlayback) {
                Label("Play Stream", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func seedIfNeeded() {
        guard !didSeed else {
            return
        }
        didSeed = true

        if let seededURL = request?.url, !seededURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlText = seededURL
            startPlayback()
        } else if urlText.isEmpty {
            // First window: seed from any launch-argument URL captured by the model.
            urlText = model.pageURLString
        }
    }

    private func startPlayback() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        model.pageURLString = trimmed
        Task {
            let started = await model.playCurrentURL()
            if started {
                RecentStreamsStore.shared.add(trimmed)
                openWindow(id: PolluxAppModel.playerWindowID)
            }
        }
    }
}
