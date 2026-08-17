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

    if UserDefaults.standard.bool(forKey: PolluxPreferences.verboseExtractionLoggingKey) {
        dumpPlaylistDiagnostics(for: extracted)
    }

    print("\nStarting playback proxy server...")
    let proxy = try StreamProxyServer(stream: extracted)
    try await proxy.start()
    let proxyURL = try await proxy.entryURL()
    print("Proxy Server is running at: \(proxyURL.absoluteString)")
    
    print("\nLaunching ffplay...")
    let process = Process()
    guard let execURL = locateExecutable(
        envName: "POLLUX_FFPLAY_PATH",
        preferredPaths: ["/usr/local/bin/ffplay", "/opt/homebrew/bin/ffplay"],
        fallbackNames: ["ffplay"]
    ) else {
        print("Error: ffplay executable not found. Make sure it's installed.")
        print("You can manually test with: ffplay \"\(proxyURL.absoluteString)\"")
        try? await Task.sleep(nanoseconds: 3600_000_000_000)
        exit(0)
    }
    process.executableURL = execURL
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

/// Prints the structure of every HLS playlist captured during extraction so a short-playback bug can be
/// diagnosed at a glance. The two ways a Pollux stream stops at ~3s look different here:
///   - a short self-contained clip is a media playlist carrying `#EXT-X-ENDLIST` with a small total
///     duration (AVPlayer plays it to the end and stops — a capture-target problem);
///   - a live feed is a media playlist WITHOUT `#EXT-X-ENDLIST` (if playback still stops at ~3s, watch
///     the `[Proxy]` lines below for repeated "serving cached copy as last resort" — a refresh problem).
private func dumpPlaylistDiagnostics(for extracted: ExtractedStream) {
    guard extracted.kind == .hls else {
        print("\n[Diag] Selected stream is \(extracted.kind.displayName), not HLS — no playlist to analyze.")
        return
    }

    guard !extracted.cachedPlaylists.isEmpty else {
        print("\n[Diag] No playlists were cached during extraction; the media playlist will only be fetched live through the proxy. Watch the [Proxy] lines during playback.")
        return
    }

    print("\n[Diag] ===== Captured HLS playlist analysis (\(extracted.cachedPlaylists.count)) =====")
    let selectedKey = extracted.streamURL.absoluteString
    for (url, playlist) in extracted.cachedPlaylists {
        let upper = playlist.uppercased()
        let isMaster = isMasterHLSPlaylist(playlist)
        let hasEndList = upper.contains("#EXT-X-ENDLIST")
        let playlistType = playlist
            .split(separator: "\n")
            .first(where: { $0.uppercased().hasPrefix("#EXT-X-PLAYLIST-TYPE") })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "(none)"

        var segmentCount = 0
        var totalDuration = 0.0
        for rawLine in playlist.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("#EXTINF:") else { continue }
            segmentCount += 1
            let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
            totalDuration += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }

        print("\n[Diag] \(url == selectedKey ? "▶ SELECTED " : "")\(url)")
        if isMaster {
            print("[Diag]   kind=MASTER (variant index; refresh not required)")
        } else {
            let classification = hasEndList
                ? "MEDIA/VOD → finite clip, AVPlayer plays to end and stops (Scenario A)"
                : "MEDIA/LIVE → sliding window, must refresh every reload (Scenario B if it still stops)"
            print("[Diag]   kind=\(classification)")
            print("[Diag]   #EXT-X-ENDLIST=\(hasEndList), \(playlistType), segments=\(segmentCount), totalDuration≈\(String(format: "%.1f", totalDuration))s")
        }

        let preview = playlist.split(separator: "\n").prefix(12).joined(separator: "\n[Diag]   | ")
        print("[Diag]   ----- first lines -----\n[Diag]   | \(preview)")
    }
    print("\n[Diag] ===== end playlist analysis =====")
}

