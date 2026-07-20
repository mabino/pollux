import AppKit
import AVFoundation
import Foundation

@MainActor
final class PolluxAppModel: ObservableObject {
    static let playerWindowID = "pollux-player-window"

    @Published var pageURLString: String
    @Published var isExtracting = false
    @Published var lastError: UserFacingError?
    @Published var player: AVPlayer?
    @Published var sourcePageURL: URL?
    @Published var extractedStreamURL: URL?
    @Published var playbackNotice: String?
    @Published var playbackError: UserFacingError?
    @Published var permissionIssue: PolluxPermissionIssue?
    @Published var isCheckingPermissions = false
    @Published var isResettingPermissions = false
    @Published var permissionActionMessage: String?

    private let extractor: BrowserStreamExtractor
    private var proxyServer: StreamProxyServer?
    private var itemObservation: NSKeyValueObservation?
    private var didRunStartupPermissionCheck = false

    init(extractor: BrowserStreamExtractor = BrowserStreamExtractor()) {
        self.extractor = extractor
        self.pageURLString = ProcessInfo.processInfo.arguments
            .dropFirst()
            .first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }) ?? ""
        self.permissionIssue = nil
    }

    func playCurrentURL() async -> Bool {
        await runStartupPermissionCheckIfNeeded()
        await updateBrowserLaunchPermissionState(triggeredByUser: false, showSuccessMessage: false)
        if permissionIssue != nil {
            return false
        }

        lastError = nil
        playbackError = nil
        playbackNotice = nil

        let pageURL: URL
        do {
            pageURL = try parsePageURL(pageURLString)
        } catch let error as PolluxError {
            lastError = error.userFacing
            return false
        } catch {
            lastError = PolluxError.invalidURL(pageURLString).userFacing
            return false
        }

        isExtracting = true
        defer { isExtracting = false }

        do {
            let extracted = try await extractor.extractPlayableStream(from: pageURL)
            try await installPlayback(for: extracted)
            return true
        } catch is CancellationError {
            return false
        } catch let error as PolluxError {
            lastError = error.userFacing
            return false
        } catch {
            lastError = PolluxError.unexpected(error.localizedDescription).userFacing
            return false
        }
    }

    func stopPlayback() {
        player?.pause()
        player = nil
        sourcePageURL = nil
        extractedStreamURL = nil
        playbackNotice = nil
        playbackError = nil
        itemObservation = nil

        guard let existingProxy = proxyServer else {
            return
        }

        proxyServer = nil
        Task {
            await existingProxy.stop()
        }
    }

    private func installPlayback(for extracted: ExtractedStream) async throws {
        let newProxy = try StreamProxyServer(stream: extracted)
        try await newProxy.start()
        let playerURL = try await newProxy.entryURL()

        let item = AVPlayerItem(url: playerURL)
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.automaticallyWaitsToMinimizeStalling = true

        player?.pause()
        if let existingProxy = proxyServer {
            Task {
                await existingProxy.stop()
            }
        }

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard let self, observedItem.status == .failed else {
                return
            }

            let reason = observedItem.error?.localizedDescription ?? "AVPlayer could not open the extracted stream."
            print("[Pollux] AVPlayerItem failed with status=.failed, error: \(String(describing: observedItem.error))")
            Task { @MainActor in
                self.playbackError = PolluxError.playbackFailed(reason).userFacing
            }
        }

        proxyServer = newProxy
        player = nextPlayer
        sourcePageURL = extracted.sourcePageURL
        extractedStreamURL = extracted.streamURL
        playbackNotice = extracted.notice
        playbackError = nil

        nextPlayer.play()
    }

    func refreshPermissions() {
        Task {
            await updateBrowserLaunchPermissionState(triggeredByUser: false, showSuccessMessage: false)
        }
    }

    func confirmGrantedAccess() async {
        await updateBrowserLaunchPermissionState(triggeredByUser: true, showSuccessMessage: true)
    }

    func runStartupPermissionCheckIfNeeded() async {
        guard !didRunStartupPermissionCheck else {
            return
        }

        didRunStartupPermissionCheck = true
        await updateBrowserLaunchPermissionState(triggeredByUser: false, showSuccessMessage: false)
    }

    func requestAccess(for issue: PolluxPermissionIssue, initiatedByUser: Bool = true) async {
        _ = issue
        await updateBrowserLaunchPermissionState(triggeredByUser: initiatedByUser, showSuccessMessage: true)
    }

    func openSystemSettings(for issue: PolluxPermissionIssue) {
        if !NSWorkspace.shared.open(issue.systemSettingsURL) {
            _ = NSWorkspace.shared.open(issue.fallbackSystemSettingsURL)
        }
    }

    func resetPermissions() async {
        guard !isResettingPermissions else {
            return
        }

        isResettingPermissions = true
        defer { isResettingPermissions = false }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.mabino.pollux"
        let issue = permissionIssue ?? .appManagement

        do {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = permissionResetArguments(for: issue, bundleIdentifier: bundleIdentifier)

                let stderr = Pipe()
                process.standardError = stderr

                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw PolluxError.unexpected(errorText.isEmpty ? "tccutil reset failed." : errorText)
                }
            }.value

            didRunStartupPermissionCheck = false
            permissionActionMessage = "Pollux permissions were reset. Press Request Access so macOS can re-evaluate App Management, then quit and reopen Pollux after granting access."
            permissionIssue = .appManagement
        } catch let error as PolluxError {
            permissionActionMessage = error.userFacing.message
        } catch {
            permissionActionMessage = error.localizedDescription
        }
    }

    private func updateBrowserLaunchPermissionState(triggeredByUser: Bool, showSuccessMessage: Bool) async {
        guard !isCheckingPermissions else {
            return
        }

        isCheckingPermissions = true
        defer { isCheckingPermissions = false }

        switch await checkChromiumLaunchAccess() {
        case .ready:
            permissionIssue = nil
            if showSuccessMessage {
                permissionActionMessage = "Pollux can launch Chromium. You can retry playback now."
            } else if permissionActionMessage?.contains("App Management") == true {
                permissionActionMessage = nil
            }

        case .missingPermission(let reason):
            permissionIssue = .appManagement
            let detail = sanitizedReason(reason, fallback: "macOS blocked Pollux from launching Chromium.")
            if triggeredByUser {
                permissionActionMessage = "Pollux still cannot launch Chromium. Grant App Management in Privacy & Security, then quit and reopen the app. \(detail)"
            } else {
                permissionActionMessage = "Pollux needs App Management so it can launch Chromium. Grant access in Privacy & Security, then quit and reopen Pollux."
            }

        case .unavailable(let reason):
            permissionIssue = nil
            if triggeredByUser || showSuccessMessage {
                permissionActionMessage = sanitizedReason(reason, fallback: "Pollux could not launch Chromium.")
            }
        }
    }

    deinit {
        guard let existingProxy = proxyServer else {
            return
        }

        Task {
            await existingProxy.stop()
        }
    }
}
