import Foundation

// Emit progress lines immediately rather than block-buffering when stdout is a pipe/redirect.
setbuf(stdout, nil)

guard CommandLine.arguments.count > 1 else {
    print("Usage: pollux-cli <stream_page_url>")
    exit(1)
}

let urlString = CommandLine.arguments[1]
guard let pageURL = safeURL(from: urlString) else {
    print("Error: Invalid page URL '\(urlString)'")
    exit(1)
}

print("Starting stream extraction for \(pageURL.absoluteString)...")
let extractor = BrowserStreamExtractor()

do {
    let extracted = try await extractor.extractPlayableStream(from: pageURL) { progressMessage, progressValue in
        print("Progress: \(progressMessage) (\(Int(progressValue * 100))%)")
    }
    
    print("\nSUCCESS: Extracted stream of kind \(extracted.kind.displayName)")
    print("Original stream URL: \(extracted.streamURL.absoluteString)")
    if let notice = extracted.notice {
        print("Notice: \(notice)")
    }
    
    print("\nStarting playback proxy server...")
    let proxy = try StreamProxyServer(stream: extracted)
    try await proxy.start()
    let proxyURL = try await proxy.entryURL()
    print("Proxy Server is running at: \(proxyURL.absoluteString)")
    
    print("\nLaunching ffplay...")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffplay")
    if !FileManager.default.fileExists(atPath: process.executableURL!.path) {
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffplay")
    }
    if !FileManager.default.fileExists(atPath: process.executableURL!.path) {
        if let resolvedPath = locateExecutablePath("ffplay") {
            process.executableURL = URL(fileURLWithPath: resolvedPath)
        }
    }
    
    guard let execURL = process.executableURL, FileManager.default.fileExists(atPath: execURL.path) else {
        print("Error: ffplay executable not found. Make sure it's installed.")
        print("You can manually test with: ffplay \"\(proxyURL.absoluteString)\"")
        try? await Task.sleep(nanoseconds: 3600_000_000_000)
        exit(0)
    }
    
    process.arguments = [proxyURL.absoluteString]
    try! process.run()
    
    print("Playing via ffplay (PID: \(process.processIdentifier)). Press Ctrl+C in terminal to stop.")
    process.waitUntilExit()
    print("ffplay exited.")
    await proxy.stop()
    
} catch {
    print("\nERROR: \(error)")
    exit(1)
}

private func locateExecutablePath(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
        return path
    }
    return nil
}
