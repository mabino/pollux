import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let permissionIssue = model.permissionIssue {
                PermissionsRequiredView(issue: permissionIssue)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Player Page URL")
                            .font(.headline)

                        TextField("https://example.com/watch/...", text: $model.pageURLString)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onSubmit(startPlayback)

                        HStack(spacing: 12) {
                            Button(action: startPlayback) {
                                Label(model.isExtracting ? "Extracting…" : "Play Stream", systemImage: model.isExtracting ? "hourglass" : "play.fill")
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isExtracting || model.pageURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if model.player != nil {
                                Button("Stop Playback", role: .destructive) {
                                    model.stopPlayback()
                                }
                            }
                        }
                    }

                    if let error = model.lastError {
                        UserFacingErrorCard(error: error)
                    }

                    if let sourcePageURL = model.sourcePageURL, let extractedStreamURL = model.extractedStreamURL {
                        GroupBox("Current Session") {
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Source Page")
                                        .font(.caption.weight(.semibold))
                                    Text(sourcePageURL.absoluteString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Extracted Stream")
                                        .font(.caption.weight(.semibold))
                                    Text(extractedStreamURL.absoluteString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                Button("Open Player Window") {
                                    openWindow(id: PolluxAppModel.playerWindowID)
                                }
                                .font(.footnote)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(18)
                .frame(minWidth: 500, minHeight: 140)
            }
        }
        .onAppear {
            Task {
                await model.runStartupPermissionCheckIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private func startPlayback() {
        Task {
            let started = await model.playCurrentURL()
            if started {
                openWindow(id: PolluxAppModel.playerWindowID)
            }
        }
    }
}
