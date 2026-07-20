import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @AppStorage(PolluxPreferences.ffprobePathKey) private var ffprobePath = ""
    @State private var selectionError: String?

    var body: some View {
        Form {
            Section {
                Text("Pollux uses ffprobe to verify extracted streams before handing them to AVPlayer. If ffprobe is not available on your PATH, save its executable location here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("ffprobe") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Current Resolution")
                        .font(.headline)

                    if let activeFFprobeURL {
                        Text(activeFFprobeURL.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)

                        Text(activeResolutionMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Pollux could not find ffprobe automatically.")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)

                        Text("Choose the ffprobe executable below, then retry playback.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved Override")
                        .font(.headline)

                    TextField("/opt/homebrew/bin/ffprobe", text: $ffprobePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())

                    HStack {
                        Button("Choose…", action: chooseFFprobe)

                        if hasSavedOverride {
                            Button("Use Automatic Discovery") {
                                ffprobePath = ""
                                selectionError = nil
                            }
                        }
                    }

                    if let selectionError {
                        Text(selectionError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if hasSavedOverride {
                        if let savedOverrideURL {
                            Text("Saved path resolves to \(savedOverrideURL.path).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("The saved path does not currently point to an executable file.")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Leave this empty to let Pollux use ffprobe from your environment or PATH.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("App Management")
                        .font(.headline)

                    if let permissionIssue = model.permissionIssue {
                        Text("Pollux is waiting for \(permissionIssue.systemSettingsLabel) access.")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)

                        Text(permissionIssue.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Pollux currently has the startup permission it checks for protected playback sites.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(model.isCheckingPermissions ? "Checking…" : "Request Access") {
                            Task {
                                await model.requestAccess(for: .appManagement)
                            }
                        }
                        .disabled(model.isCheckingPermissions)

                        Button("Open Privacy & Security") {
                            if let permissionIssue = model.permissionIssue {
                                model.openSystemSettings(for: permissionIssue)
                            } else {
                                _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                            }
                        }

                        Button(model.isResettingPermissions ? "Resetting…" : "Reset Permissions") {
                            Task {
                                await model.resetPermissions()
                            }
                        }
                        .disabled(model.isResettingPermissions)

                        Button(model.isCheckingPermissions ? "Checking…" : "Refresh Status") {
                            Task {
                                await model.confirmGrantedAccess()
                            }
                        }
                        .disabled(model.isCheckingPermissions)
                    }

                    Text("Reset Permissions runs tccutil reset AppManagement for Pollux. After resetting, press Request Access so macOS can prompt again, then quit and reopen Pollux once Chromium can launch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let permissionActionMessage = model.permissionActionMessage {
                        NoticeCard(text: permissionActionMessage)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onChange(of: ffprobePath) { _, _ in
            selectionError = nil
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 300)
    }

    private var trimmedFFprobePath: String {
        ffprobePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSavedOverride: Bool {
        !trimmedFFprobePath.isEmpty
    }

    private var savedOverrideURL: URL? {
        resolveExecutablePath(trimmedFFprobePath)
    }

    private var activeFFprobeURL: URL? {
        locateExecutable(
            envName: "POLLUX_FFPROBE_PATH",
            defaultsKey: PolluxPreferences.ffprobePathKey,
            fallbackNames: ["ffprobe"]
        )
    }

    private var autoDetectedFFprobeURL: URL? {
        locateExecutable(
            envName: "POLLUX_FFPROBE_PATH",
            fallbackNames: ["ffprobe"]
        )
    }

    private var activeResolutionMessage: String {
        if ProcessInfo.processInfo.environment["POLLUX_FFPROBE_PATH"]?.isEmpty == false {
            return "Using the POLLUX_FFPROBE_PATH environment override."
        }
        if hasSavedOverride {
            return "Using the saved Settings override."
        }
        if autoDetectedFFprobeURL != nil {
            return "Found automatically from your PATH."
        }
        return "Pollux will use this path the next time you start playback."
    }

    private func chooseFFprobe() {
        let panel = NSOpenPanel()
        panel.title = "Choose ffprobe"
        panel.message = "Select the ffprobe executable Pollux should use for stream validation."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let currentURL = savedOverrideURL {
            panel.directoryURL = currentURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        guard let resolvedURL = resolveExecutablePath(selectedURL.path) else {
            selectionError = "Choose the ffprobe executable itself, not a folder or a non-executable file."
            return
        }

        ffprobePath = resolvedURL.path
        selectionError = nil
    }
}
