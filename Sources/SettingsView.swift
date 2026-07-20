import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @AppStorage(PolluxPreferences.ffprobePathKey) private var ffprobePath = ""
    @State private var selectionError: String?

    var body: some View {
        Form {
            Section("Dependencies") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ffprobe Binary")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField(effectiveFFprobePlaceholder, text: $ffprobePath)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())

                        Button("Choose…", action: chooseFFprobe)

                        if !ffprobePath.isEmpty {
                            Button("Clear") {
                                ffprobePath = ""
                                selectionError = nil
                            }
                        }
                    }

                    if let selectionError {
                        Text(selectionError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else {
                        HStack(spacing: 6) {
                            if activeFFprobeURL != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            }
                            Text(ffprobeStatusMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Chromium / Google Chrome")
                        .font(.headline)

                    HStack(spacing: 6) {
                        if let chromiumURL = detectedChromiumURL {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Found at \(chromiumURL.path)")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("Chromium / Google Chrome was not found in standard locations or via POLLUX_CHROME_PATH.")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("App Management Access")
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
                        Text("Pollux currently has the App Management permission required for launching Chromium.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button(model.isCheckingPermissions ? "Checking…" : "Request Access") {
                            Task {
                                await model.requestAccess(for: .appManagement)
                            }
                        }
                        .disabled(model.isCheckingPermissions)

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

                    Text("Reset Permissions runs `tccutil reset AppManagement`. Press Request Access afterwards so macOS can prompt again.")
                        .font(.caption)
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
        .frame(minWidth: 560, minHeight: 320)
    }

    private var trimmedFFprobePath: String {
        ffprobePath.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var detectedChromiumURL: URL? {
        locateChromiumExecutable()
    }

    private var effectiveFFprobePlaceholder: String {
        if let autoPath = autoDetectedFFprobeURL?.path {
            return autoPath
        }
        return "/opt/homebrew/bin/ffprobe"
    }

    private var ffprobeStatusMessage: String {
        if ProcessInfo.processInfo.environment["POLLUX_FFPROBE_PATH"]?.isEmpty == false {
            return "Using POLLUX_FFPROBE_PATH environment variable."
        }
        if !trimmedFFprobePath.isEmpty {
            if let savedOverrideURL {
                return "Using custom path: \(savedOverrideURL.path)"
            } else {
                return "Saved path does not point to a valid executable."
            }
        }
        if let autoDetectedFFprobeURL {
            return "Auto-detected at \(autoDetectedFFprobeURL.path)"
        }
        return "ffprobe not found. Please specify the executable path above."
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
        if let currentURL = savedOverrideURL ?? activeFFprobeURL {
            panel.directoryURL = currentURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        guard let resolvedURL = resolveExecutablePath(selectedURL.path) else {
            selectionError = "Choose the ffprobe executable itself, not a folder or non-executable file."
            return
        }

        ffprobePath = resolvedURL.path
        selectionError = nil
    }
}
