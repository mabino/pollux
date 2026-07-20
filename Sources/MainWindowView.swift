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
                            .disabled(model.isExtracting)

                        if model.isExtracting {
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

                        HStack(spacing: 12) {
                            if model.isExtracting {
                                Button(role: .destructive) {
                                    model.cancelExtraction()
                                } label: {
                                    Label("Stop Extracting", systemImage: "stop.fill")
                                }
                            } else {
                                Button(action: startPlayback) {
                                    Label("Play Stream", systemImage: "play.fill")
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(model.player != nil || model.pageURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            if model.player != nil {
                                Button("Open Player Window") {
                                    openWindow(id: PolluxAppModel.playerWindowID)
                                }

                                Button("Stop Playback", role: .destructive) {
                                    model.stopPlayback()
                                }
                            }
                        }
                    }

                    if let error = model.lastError {
                        UserFacingErrorCard(error: error)
                    }
                }
                .padding(18)
                .frame(minWidth: 500, minHeight: 120)
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
