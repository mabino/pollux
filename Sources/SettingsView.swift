import AppKit
import SwiftUI

struct SettingsView: View {
    /// Injected by the app so the Sparkle updates UI stays out of the base view (and out of the CLI /
    /// test targets, which don't link Sparkle). Nil when there is no updater.
    var updatesSection: AnyView? = nil
    @EnvironmentObject private var model: PolluxAppModel
    @AppStorage(PolluxPreferences.ffprobePathKey) private var ffprobePath = ""
    @AppStorage(PolluxPreferences.verboseExtractionLoggingKey) private var verboseExtractionLogging = false
    @AppStorage(PolluxPreferences.captureRetryBudgetKey) private var captureRetryBudget = CaptureRetryBudget.defaultSeconds
    @AppStorage(PolluxPreferences.headfulExtractionKey) private var headfulExtraction = false
    @AppStorage(PolluxPreferences.releaseBrowserAfterExtractionKey) private var releaseBrowserAfterExtraction = false
    @AppStorage(PolluxPreferences.antiAutomationLevelKey) private var antiAutomationLevel = AntiAutomationLevel.off.rawValue
    @AppStorage(PolluxPreferences.streamLibraryRetentionKey) private var streamLibraryRetention = StreamLibraryStore.defaultRetention
    @AppStorage(PolluxPreferences.mediaRelayKey) private var mediaRelay = false
    @State private var selectionError: String?

    var body: some View {
        TabView {
            extractionTab
                .tabItem { Label("Extraction", systemImage: "antenna.radiowaves.left.and.right") }

            dependenciesTab
                .tabItem { Label("Dependencies", systemImage: "wrench.and.screwdriver") }

            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "ladybug") }

            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            if let updatesSection {
                Form { updatesSection }
                    .formStyle(.grouped)
                    .padding(20)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .frame(width: 600, height: 400)
        .onChange(of: ffprobePath) { _, _ in
            selectionError = nil
        }
    }

    private var extractionTab: some View {
        Form {
            Section("Capture") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Capture retry time")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(clampedRetryBudget))s")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $captureRetryBudget,
                        in: CaptureRetryBudget.minSeconds...CaptureRetryBudget.maxSeconds,
                        step: 15
                    ) {
                        Text("Capture retry time")
                    } minimumValueLabel: {
                        Text("\(Int(CaptureRetryBudget.minSeconds))s")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("\(Int(CaptureRetryBudget.maxSeconds))s")
                            .font(.caption)
                    }

                    Text("How long Pollux keeps retrying before giving up. Some sites detect automation and serve a blank page on most loads, so Pollux re-navigates to try again. A longer budget catches more streams but wastes more time when a stream truly isn't available. Default is \(Int(CaptureRetryBudget.defaultSeconds))s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Browser") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Anti-automation mitigation", selection: $antiAutomationLevel) {
                        Text("Off").tag(AntiAutomationLevel.off.rawValue)
                        Text("Standard").tag(AntiAutomationLevel.standard.rawValue)
                    }
                    .pickerStyle(.radioGroup)

                    Text(antiAutomationHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use a visible browser (headful)", isOn: $headfulExtraction)

                    Text("Some sites detect headless Chromium and serve a black or blocked page. Enabling this launches a visible Chromium window during extraction, which can bypass those blocks. A browser window will briefly appear while Pollux finds the stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Close browser after extraction", isOn: $releaseBrowserAfterExtraction)

                    Text("Frees the Chromium instance as soon as a stream is found, reducing memory use. Live streams then refresh over direct connections only (no browser fallback), which some CDNs reject — leave off if live playback stalls after a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Relay player media (experimental)", isOn: $mediaRelay)

                    Text("For sites whose CDN rejects every request except the in-page player's, keep the (visible) browser playing and serve the player's own downloaded video to Pollux. This forces a visible browser and keeps it running for the whole session — expect higher CPU and memory, and playback that trails the browser by a few seconds. Try Standard anti-automation too if the browser itself can't load the stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Previous Streams") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Streams to remember", selection: $streamLibraryRetention) {
                        Text("None").tag(0)
                        Text("5").tag(5)
                        Text("20").tag(20)
                        Text("50").tag(50)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: streamLibraryRetention) { _, _ in
                        StreamLibraryStore.shared.enforceRetentionLimit()
                    }

                    Text("How many previously extracted streams Pollux keeps in the Previous Streams window, so you can resume one without re-running extraction. \"None\" disables the history. Stored entries include the captured request headers and cookies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var dependenciesTab: some View {
        Form {
            Section("ffprobe") {
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
            }

            Section("Browser") {
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
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var diagnosticsTab: some View {
        Form {
            Section("Logging") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Verbose extraction logging", isOn: $verboseExtractionLogging)

                    Text("Adds a line to the Extraction Log for every browser network request, response, and console message. Useful for debugging why a stream can't be found, but very noisy. Leave off for normal use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var permissionsTab: some View {
        Form {
            Section("App Management") {
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
        .padding(20)
    }

    private var clampedRetryBudget: TimeInterval {
        CaptureRetryBudget.clamp(captureRetryBudget)
    }

    private var antiAutomationHelpText: String {
        switch AntiAutomationLevel(rawValue: antiAutomationLevel) ?? .off {
        case .off:
            return "Fast extraction using the standard browser automation interface. Most capable, but some sites detect it and serve a blank or frozen page."
        case .standard:
            return "Hides the automation control channel most bot-detectors watch for: Pollux runs its page checks in an isolated context and strengthens the browser fingerprint. Use this when a page loads and then freezes or blanks under normal extraction."
        }
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
