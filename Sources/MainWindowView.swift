import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let permissionIssue = model.permissionIssue {
                PermissionsRequiredView(issue: permissionIssue)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pollux")
                            .font(.largeTitle.bold())

                        Text("Paste a player page URL. Pollux follows Castor's Chromium + network-capture approach, validates candidates with ffprobe, and opens the extracted stream in a native macOS player window.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
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
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Source Page")
                                        .font(.subheadline.weight(.semibold))
                                    Text(sourcePageURL.absoluteString)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Extracted Stream")
                                        .font(.subheadline.weight(.semibold))
                                    Text(extractedStreamURL.absoluteString)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                Button("Open Player Window") {
                                    openWindow(id: PolluxAppModel.playerWindowID)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Spacer(minLength: 0)

                    GroupBox("Runtime Requirements") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pollux needs Chromium or Google Chrome for extraction and ffprobe for stream validation.")
                            Text("Choose Pollux > Settings… to save a custom ffprobe path, or use POLLUX_CHROME_PATH and POLLUX_FFPROBE_PATH for environment-based overrides.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
                .frame(minWidth: 680, minHeight: 460)
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
