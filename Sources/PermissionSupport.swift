import Foundation

enum PolluxPermissionIssue: String, CaseIterable, Identifiable, Sendable {
    case appManagement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appManagement:
            return "Pollux Needs App Management"
        }
    }

    var summary: String {
        switch self {
        case .appManagement:
            return "Pollux launches Chromium headlessly so it can inspect protected HLS players. On this system, macOS may require App Management before Pollux can start Chromium from inside the app."
        }
    }

    var instructions: [String] {
        switch self {
        case .appManagement:
            return [
                "Press Request Access so Pollux can try to launch Chromium and trigger the App Management prompt if macOS requires it.",
                "Open Privacy & Security and enable Pollux under App Management.",
                "If Pollux is already listed but still fails, use Pollux > Settings… and press Reset Permissions, then Request Access again.",
            ]
        }
    }

    var systemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement")!
    }

    var fallbackSystemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    }

    var systemSettingsLabel: String {
        switch self {
        case .appManagement:
            return "App Management"
        }
    }
}

func permissionResetArguments(for issue: PolluxPermissionIssue, bundleIdentifier: String) -> [String] {
    switch issue {
    case .appManagement:
        return ["reset", "AppManagement", bundleIdentifier]
    }
}

enum BrowserLaunchAccessStatus: Sendable {
    case ready
    case missingPermission(String)
    case unavailable(String)
}

func checkChromiumLaunchAccess() async -> BrowserLaunchAccessStatus {
    guard locateChromiumExecutable() != nil else {
        return .unavailable(PolluxError.chromiumMissing.userFacing.message)
    }

    return await Task.detached(priority: .userInitiated) {
        guard let executableURL = locateChromiumExecutable() else {
            return .unavailable(PolluxError.chromiumMissing.userFacing.message)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let combined = (output + "\n" + errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                return classifyBrowserLaunchFailure(
                    combined.isEmpty ? "Chromium exited with status \(process.terminationStatus)." : combined
                )
            }

            return .ready
        } catch {
            return classifyBrowserLaunchFailure(error.localizedDescription)
        }
    }.value
}

private func classifyBrowserLaunchFailure(_ rawReason: String) -> BrowserLaunchAccessStatus {
    let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
    if looksLikeAppManagementDenial(reason) {
        return .missingPermission(reason.isEmpty ? "macOS blocked Pollux from launching Chromium." : reason)
    }
    return .unavailable(reason.isEmpty ? "Pollux could not launch Chromium." : reason)
}

private func looksLikeAppManagementDenial(_ reason: String) -> Bool {
    let lowered = reason.lowercased()
    return lowered.contains("app management")
        || lowered.contains("not permitted")
        || lowered.contains("permission")
        || lowered.contains("operation couldn't be completed")
        || lowered.contains("operation couldn’t be completed")
}
