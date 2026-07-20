import AppKit
import Foundation

final class BrowserStreamExtractor: @unchecked Sendable {
    private let settings = ExtractionSettings()

    func extractPlayableStream(from sourcePageURL: URL) async throws -> ExtractedStream {
        let profile = BrowserProfile.random()
        let collector = CaptureCollector(patterns: settings.capturePatterns, maxCandidates: settings.maxCandidates)
        let session = try await ChromeBrowserSession.launch(profile: profile) { method, params in
            await collector.handleEvent(method: method, paramsData: params)
        }

        do {
            return try await withTimeout(seconds: settings.extractionTimeout) { [self] in
                do {
                    try await session.navigate(to: sourcePageURL, timeout: self.settings.browserTimeout)
                } catch {
                    if !(await collector.hasHits()) {
                        throw error
                    }
                }

                try await self.runActionPipeline(session: session, collector: collector, profile: profile)
                let entries = await collector.waitForEntries(
                    graceAfterActions: self.settings.graceAfterActions,
                    collectionWindow: self.settings.collectionWindow
                )
                guard !entries.isEmpty else {
                    throw PolluxError.noStreamCaptured(sourcePageURL)
                }

                let cookies = try await session.cookies()
                let cachedPlaylists = await self.cachePlaylists(from: entries, session: session)
                let candidates = self.buildCandidates(
                    from: entries,
                    cachedPlaylists: cachedPlaylists,
                    cookies: cookies,
                    sourcePageURL: sourcePageURL,
                    userAgent: profile.userAgent
                )
                guard !candidates.isEmpty else {
                    throw PolluxError.noStreamCaptured(sourcePageURL)
                }

                let selection = try await self.selectBestCandidate(from: candidates, cachedPlaylists: cachedPlaylists)

                return ExtractedStream(
                    sourcePageURL: sourcePageURL,
                    streamURL: selection.candidate.url,
                    headers: selection.candidate.headers,
                    kind: selection.kind,
                    cachedPlaylists: cachedPlaylists,
                    notice: selection.notice,
                    session: session
                )
            }
        } catch {
            await session.close()
            if let polluxError = error as? PolluxError {
                throw polluxError
            }
            throw PolluxError.unexpected(error.localizedDescription)
        }
    }

    private func runActionPipeline(
        session: ChromeBrowserSession,
        collector: CaptureCollector,
        profile: BrowserProfile
    ) async throws {
        let deadline = Date().addingTimeInterval(settings.browserTimeout)

        while Date() < deadline {
            if await collector.hasHits() {
                return
            }

            if let iframeSource = await session.pollForIframeSource(timeout: 2.0),
               let iframeURL = URL(string: iframeSource) {
                print("[CDP Pipeline] Found iframe: \(iframeURL.absoluteString)")
                try? await session.navigate(to: iframeURL, referrer: session.currentURL?.absoluteString, timeout: 3)
            }

            if await collector.hasHits() {
                return
            }

            await session.clickPlayButtons()

            if await collector.hasHits() {
                return
            }

            try? await session.bypassTurnstile(
                solveTimeout: settings.turnstileSolveTimeout,
                retryTimeout: settings.turnstileRetryTimeout
            )

            if await collector.hasHits() {
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func cachePlaylists(from entries: [CapturedEntry], session: ChromeBrowserSession) async -> [String: String] {
        var cachedPlaylists: [String: String] = [:]
        var pendingURLs = entries.compactMap { entry -> URL? in
            guard let url = URL(string: entry.rawURL),
                  StreamKind.detect(url: url, mimeType: entry.mimeType) == .hls
            else {
                return nil
            }
            return url
        }
        var visited = Set<String>()

        while let playlistURL = pendingURLs.popLast() {
            if visited.count >= settings.maxCachedPlaylists {
                break
            }
            let cacheKey = playlistURL.absoluteString
            guard visited.insert(cacheKey).inserted else {
                continue
            }

            let text: String
            if let cached = cachedPlaylists[cacheKey] {
                text = cached
            } else {
                guard
                    let fetched = try? await session.fetchTextResource(
                        at: playlistURL,
                        timeout: settings.playlistFetchTimeout
                    ),
                    !fetched.isEmpty,
                    !fetched.hasPrefix("ERROR:")
                else {
                    continue
                }
                cachedPlaylists[cacheKey] = fetched
                text = fetched
            }

            for referencedURL in referencedHLSPlaylistURLs(in: text, playlistURL: playlistURL) {
                if !visited.contains(referencedURL.absoluteString) {
                    pendingURLs.append(referencedURL)
                }
            }
        }
        return cachedPlaylists
    }

    private func buildCandidates(
        from entries: [CapturedEntry],
        cachedPlaylists: [String: String],
        cookies: [BrowserCookie],
        sourcePageURL: URL,
        userAgent: String
    ) -> [StreamCandidate] {
        var deduped: [String: StreamCandidate] = [:]
        var capturedHLSHeadersByHost: [String: [String: String]] = [:]

        for entry in entries {
            guard
                let url = URL(string: entry.rawURL),
                let kind = StreamKind.detect(url: url, mimeType: entry.mimeType)
            else {
                continue
            }

            let headers = candidateHeaders(
                for: url,
                capturedHeaders: entry.headers,
                sourcePageURL: sourcePageURL,
                userAgent: userAgent,
                cookies: cookies
            )
            if kind == .hls, let host = url.host?.lowercased() {
                capturedHLSHeadersByHost[host] = headers
            }

            registerCandidate(
                StreamCandidate(url: url, headers: headers, kind: kind, score: entry.score),
                into: &deduped
            )
        }

        for cachedPlaylistURL in cachedPlaylists.keys {
            guard
                let url = URL(string: cachedPlaylistURL),
                StreamKind.detect(url: url, mimeType: nil) == .hls
            else {
                continue
            }

            let headers = candidateHeaders(
                for: url,
                capturedHeaders: capturedHLSHeadersByHost[url.host?.lowercased() ?? ""] ?? [:],
                sourcePageURL: sourcePageURL,
                userAgent: userAgent,
                cookies: cookies
            )
            if let host = url.host?.lowercased(), capturedHLSHeadersByHost[host] == nil {
                capturedHLSHeadersByHost[host] = headers
            }

            registerCandidate(
                StreamCandidate(url: url, headers: headers, kind: .hls, score: rankCachedPlaylistURL(url)),
                into: &deduped
            )
        }

        return deduped.values.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }

    private func candidateHeaders(
        for url: URL,
        capturedHeaders: [String: String],
        sourcePageURL: URL,
        userAgent: String,
        cookies: [BrowserCookie]
    ) -> [String: String] {
        var headers = canonicalizedHeaders(capturedHeaders, sourcePageURL: sourcePageURL, userAgent: userAgent)
        let cookieString = cookiesHeader(for: url, cookies: cookies)
        if !cookieString.isEmpty {
            if let existing = headers["Cookie"], !existing.isEmpty {
                headers["Cookie"] = existing + "; " + cookieString
            } else {
                headers["Cookie"] = cookieString
            }
        }
        return headers
    }

    private func registerCandidate(_ candidate: StreamCandidate, into deduped: inout [String: StreamCandidate]) {
        let key = candidate.url.absoluteString
        if let existing = deduped[key], existing.score >= candidate.score {
            return
        }
        deduped[key] = candidate
    }

    private func rankCachedPlaylistURL(_ url: URL) -> Int {
        let path = url.path.lowercased()
        var score = 0

        if path.contains("master") {
            score += 100
        }
        if path.contains("playlist") {
            score += 50
        }
        for pattern in ["/720p/", "/1080p/", "/480p/", "/360p/", "/240p/", "/chunklist", "/media-", "/segment"] {
            if path.contains(pattern) {
                score -= 50
                break
            }
        }

        return score
    }

    private func selectBestCandidate(
        from candidates: [StreamCandidate],
        cachedPlaylists: [String: String]
    ) async throws -> CandidateSelection {
        let prober = try FFprobeService()

        let evaluations = await withTaskGroup(of: ProbeEvaluation.self, returning: [ProbeEvaluation].self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let result = try await probeCandidate(candidate, with: prober, cachedPlaylists: cachedPlaylists)
                        return .success(candidate, result)
                    } catch {
                        return .failure(candidate, error.localizedDescription)
                    }
                }
            }

            var collected: [ProbeEvaluation] = []
            for await evaluation in group {
                collected.append(evaluation)
            }
            return collected
        }

        var playable: [(candidate: StreamCandidate, kind: StreamKind, bitRate: Int64)] = []
        var fallbacks: [StreamCandidate] = []
        var unsupportedKinds = Set<String>()

        for evaluation in evaluations {
            switch evaluation {
            case .success(let candidate, let result):
                let resolvedKind = result.kind ?? candidate.kind
                if !resolvedKind.avPlayerSupported {
                    unsupportedKinds.insert(resolvedKind.displayName)
                    continue
                }
                if result.playable {
                    playable.append((candidate, resolvedKind, max(result.bitRate, 1)))
                }

            case .failure(let candidate, _):
                if candidate.kind.avPlayerSupported {
                    fallbacks.append(candidate)
                } else {
                    unsupportedKinds.insert(candidate.kind.displayName)
                }
            }
        }

        let preferredPlayableCandidates = preferredPlaybackCandidates(
            from: playable.map(\.candidate),
            cachedPlaylists: cachedPlaylists
        )
        let playablePool = preferredPlayableCandidates.isEmpty
            ? playable
            : playable.filter { candidate, _, _ in
                preferredPlayableCandidates.contains { $0.url == candidate.url }
            }

        if let bestPlayable = playablePool.max(by: { lhs, rhs in
            if lhs.bitRate != rhs.bitRate {
                return lhs.bitRate < rhs.bitRate
            }
            return lhs.candidate.score < rhs.candidate.score
        }) {
            return CandidateSelection(candidate: bestPlayable.candidate, kind: bestPlayable.kind, notice: nil)
        }

        if let masterFallback = bestMasterPlaylistCandidate(from: candidates, cachedPlaylists: cachedPlaylists) {
            return CandidateSelection(
                candidate: masterFallback,
                kind: .hls,
                notice: "Pollux is using a browser-cached HLS master playlist because ffprobe could not verify the final variant layout."
            )
        }

        if let fallback = fallbacks.sorted(by: { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }).first {
            return CandidateSelection(
                candidate: fallback,
                kind: fallback.kind,
                notice: "Pollux couldn't verify this stream with ffprobe, so playback is a best-effort attempt."
            )
        }

        if !unsupportedKinds.isEmpty {
            throw PolluxError.unsupportedFormats(Array(unsupportedKinds).sorted())
        }

        throw PolluxError.noPlayableStream
    }
}

private func probeCandidate(
    _ candidate: StreamCandidate,
    with prober: FFprobeService,
    cachedPlaylists: [String: String]
) async throws -> ProbeResult {
    guard candidate.kind == .hls else {
        return try await prober.probe(candidate: candidate)
    }

    do {
        return try await probeHLSCandidateThroughProxy(candidate, with: prober, cachedPlaylists: cachedPlaylists)
    } catch {
        return try await prober.probe(candidate: candidate)
    }
}

private func probeHLSCandidateThroughProxy(
    _ candidate: StreamCandidate,
    with prober: FFprobeService,
    cachedPlaylists: [String: String]
) async throws -> ProbeResult {
    let extracted = ExtractedStream(
        sourcePageURL: candidate.url,
        streamURL: candidate.url,
        headers: candidate.headers,
        kind: candidate.kind,
        cachedPlaylists: cachedPlaylists,
        notice: nil
    )
    let proxy = try StreamProxyServer(stream: extracted)

    do {
        try await proxy.start()
        let localURL = try await proxy.entryURL()
        let proxiedCandidate = StreamCandidate(url: localURL, headers: [:], kind: .hls, score: candidate.score)
        let result = try await prober.probe(candidate: proxiedCandidate)
        await proxy.stop()
        return result
    } catch {
        await proxy.stop()
        throw error
    }
}

private func bestMasterPlaylistCandidate(
    from candidates: [StreamCandidate],
    cachedPlaylists: [String: String]
) -> StreamCandidate? {
    candidates
        .filter { candidate in
            guard candidate.kind == .hls,
                  let playlist = cachedPlaylists[candidate.url.absoluteString]
            else {
                return false
            }
            return isMasterHLSPlaylist(playlist)
        }
        .max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.url.absoluteString > rhs.url.absoluteString
        }
}

private struct ExtractionSettings {
    let browserTimeout: TimeInterval = 30
    let graceAfterActions: TimeInterval = 15
    let collectionWindow: TimeInterval = 10
    let extractionTimeout: TimeInterval = 60
    let playlistFetchTimeout: TimeInterval = 6
    let maxCachedPlaylists = 12
    let navigateIframeTimeout: TimeInterval = 10
    let navigateIframeMaxDepth = 5
    let turnstileSolveTimeout: TimeInterval = 20
    let turnstileRetryTimeout: TimeInterval = 10
    let capturePatterns = [
        #"\.m3u8"#,
        #"master\.m3u8"#,
        #"index\.m3u8"#,
        #"/playlist/"#,
    ]
    let maxCandidates = 100
}

struct BrowserProfile {
    let userAgent: String
    let acceptLanguage: String
    let platform: String
    let windowWidth: Int
    let windowHeight: Int

    var centerX: Double { Double(windowWidth) / 2 }
    var centerY: Double { Double(windowHeight) / 2 }

    var stealthScript: String {
        """
        (() => {
          const patch = (target, key, value) => Object.defineProperty(target, key, {
            get: () => value,
            configurable: true
          });
          patch(navigator, 'webdriver', undefined);
          patch(navigator, 'platform', '\(platform)');
          patch(navigator, 'languages', ['en-US', 'en']);
          patch(navigator, 'plugins', [1, 2, 3, 4, 5]);
          window.chrome = window.chrome || { runtime: {} };
          const originalQuery = navigator.permissions && navigator.permissions.query;
          if (originalQuery) {
            navigator.permissions.query = (parameters) => {
              if (parameters && parameters.name === 'notifications') {
                return Promise.resolve({ state: Notification.permission });
              }
              return originalQuery.call(navigator.permissions, parameters);
            };
          }
        })();
        """
    }

    static func random() -> BrowserProfile {
        let presets: [BrowserProfile] = [
            BrowserProfile(
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
                acceptLanguage: "en-US,en;q=0.9",
                platform: "MacIntel",
                windowWidth: 1920,
                windowHeight: 1080
            ),
            BrowserProfile(
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36",
                acceptLanguage: "en-US,en;q=0.9",
                platform: "Win32",
                windowWidth: 1536,
                windowHeight: 864
            ),
            BrowserProfile(
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                acceptLanguage: "en-US,en;q=0.9",
                platform: "Win32",
                windowWidth: 2560,
                windowHeight: 1440
            ),
        ]

        return presets.randomElement() ?? presets[0]
    }
}

private struct CandidateSelection {
    let candidate: StreamCandidate
    let kind: StreamKind
    let notice: String?
}

private enum ProbeEvaluation {
    case success(StreamCandidate, ProbeResult)
    case failure(StreamCandidate, String)
}

final class ChromiumProcessTracker: @unchecked Sendable {
    static let shared = ChromiumProcessTracker()

    private struct TrackedSession {
        let process: Process
        let userDataDirectory: URL
    }

    private var sessions: [UUID: TrackedSession] = [:]
    private let lock = NSLock()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func register(id: UUID, process: Process, userDataDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        sessions[id] = TrackedSession(process: process, userDataDirectory: userDataDirectory)
    }

    func unregister(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: id)
    }

    func terminateSession(id: UUID) {
        lock.lock()
        let tracked = sessions.removeValue(forKey: id)
        lock.unlock()

        if let tracked {
            if tracked.process.isRunning {
                tracked.process.terminate()
                tracked.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: tracked.userDataDirectory)
        }
    }

    @objc private func handleAppWillTerminate() {
        terminateAll()
    }

    func terminateAll() {
        lock.lock()
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        for tracked in allSessions {
            if tracked.process.isRunning {
                tracked.process.terminate()
            }
            try? FileManager.default.removeItem(at: tracked.userDataDirectory)
        }
    }
}

final class ChromeBrowserSession: @unchecked Sendable {
    let id: UUID
    private static let largestIframeScript = """
    (function() {
      const iframes = document.querySelectorAll('iframe');
      let best = null, maxArea = 0;
      for (const f of iframes) {
        const src = f.src || f.getAttribute('data-src') || f.getAttribute('data-url') || '';
        if (!src || src.startsWith('about:') || src.startsWith('javascript:')) continue;
        const r = f.getBoundingClientRect();
        const a = r.width * r.height;
        if (a > maxArea && r.width > 50 && r.height > 50) { maxArea = a; best = src; }
      }
      if (best) return best;
      for (const f of iframes) {
        const src = f.src || f.getAttribute('data-src') || f.getAttribute('data-url') || '';
        if (src && (src.startsWith('http://') || src.startsWith('https://'))) return src;
      }
      return null;
    })()
    """

    private static let turnstilePositionScript = """
    (function() {
        const c = document.querySelector('.cf-turnstile');
        if (!c) return null;
        const f = c.querySelector('iframe');
        if (!f) return null;
        const r = f.getBoundingClientRect();
        if (r.width < 10 || r.height < 10) return null;
        return {x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)};
    })()
    """

    private static let turnstileGoneScript = "document.querySelector('.cf-turnstile') === null"
    private static let startupTimeout: TimeInterval = 30
    private static let targetDiscoveryTimeout: TimeInterval = 15

    private let process: Process
    private let userDataDirectory: URL
    private let connection: CDPConnection
    private var closed = false
    private(set) var currentURL: URL?

    private init(id: UUID, process: Process, userDataDirectory: URL, connection: CDPConnection) {
        self.id = id
        self.process = process
        self.userDataDirectory = userDataDirectory
        self.connection = connection
    }

    static func launch(
        profile: BrowserProfile,
        eventHandler: @escaping @Sendable (String, Data) async -> Void
    ) async throws -> ChromeBrowserSession {
        guard let executableURL = locateChromiumExecutable() else {
            throw PolluxError.chromiumMissing
        }

        let id = UUID()
        let userDataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pollux-chrome-\(id.uuidString)")
        try FileManager.default.createDirectory(at: userDataDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executableURL
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let diagnostics = ChromeLaunchDiagnostics(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        process.arguments = [
            "--remote-debugging-port=0",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--headless=new",
            "--disable-dev-shm-usage",
            "--disable-blink-features=AutomationControlled",
            "--disable-infobars",
            "--use-mock-keychain",
            "--enable-features=NetworkService,NetworkServiceInProcess",
            "--disable-background-timer-throttling",
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--autoplay-policy=no-user-gesture-required",
            "--incognito",
            "--window-size=\(profile.windowWidth),\(profile.windowHeight)",
            "--user-agent=\(profile.userAgent)",
            "about:blank",
        ]

        do {
            try process.run()
            ChromiumProcessTracker.shared.register(id: id, process: process, userDataDirectory: userDataDirectory)

            let port = try await waitForDebugPort(
                process: process,
                diagnostics: diagnostics,
                userDataDirectory: userDataDirectory,
                timeout: startupTimeout
            )
            let webSocketURL = try await waitForPageSocketURL(
                port: port,
                diagnostics: diagnostics,
                timeout: targetDiscoveryTimeout
            )
            let connection = CDPConnection(webSocketURL: webSocketURL)
            await connection.start()
            await connection.setEventHandler(eventHandler)

            let session = ChromeBrowserSession(
                id: id,
                process: process,
                userDataDirectory: userDataDirectory,
                connection: connection
            )
            try await session.configure(profile: profile)
            diagnostics.stop()
            return session
        } catch {
            diagnostics.stop()
            ChromiumProcessTracker.shared.terminateSession(id: id)
            if let polluxError = error as? PolluxError {
                throw polluxError
            }
            throw PolluxError.browserLaunchFailed(error.localizedDescription)
        }
    }

    func navigate(to url: URL, referrer: String? = nil, timeout: TimeInterval) async throws {
        var params: [String: Any] = ["url": url.absoluteString]
        if let referrer {
            params["referrer"] = referrer
        }
        currentURL = url
        _ = try await connection.call("Page.navigate", params: params)
        do {
            try await waitForDocumentReady(timeout: timeout)
        } catch {
            throw PolluxError.navigationTimedOut(url)
        }
    }

    func click(x: Double, y: Double) async throws {
        _ = try await connection.call("Input.dispatchMouseEvent", params: [
            "type": "mouseMoved",
            "x": x,
            "y": y,
        ])
        _ = try await connection.call("Input.dispatchMouseEvent", params: [
            "type": "mousePressed",
            "x": x,
            "y": y,
            "button": "left",
            "clickCount": 1,
        ])
        _ = try await connection.call("Input.dispatchMouseEvent", params: [
            "type": "mouseReleased",
            "x": x,
            "y": y,
            "button": "left",
            "clickCount": 1,
        ])
    }

    func pollForIframeSource(timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let src = try? await evaluateString(ChromeBrowserSession.largestIframeScript),
               !src.isEmpty {
                return src
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    func clickPlayButtons() async {
        let script = """
        (() => {
          const selectors = ['button', '.play-btn', '.vjs-big-play-button', '#player', '[class*="play"]', '[id*="play"]', 'a.btn'];
          for (const s of selectors) {
            const el = document.querySelector(s);
            if (el && typeof el.click === 'function') {
              el.click();
              return true;
            }
          }
          return false;
        })()
        """
        _ = try? await evaluateBool(script)
    }

    func navigateIntoLargestIframes(timeout: TimeInterval, maxDepth: Int) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<maxDepth {
            try Task.checkCancellation()
            guard Date() < deadline else {
                return
            }
            let remaining = max(deadline.timeIntervalSinceNow, 0.5)
            guard let iframeSource = await pollForIframeSource(timeout: remaining),
                  let iframeURL = URL(string: iframeSource)
            else {
                return
            }
            _ = try await connection.call("Page.navigate", params: ["url": iframeURL.absoluteString])
            try await waitForDocumentReady(timeout: min(3, max(deadline.timeIntervalSinceNow, 1)))
        }
    }

    func bypassTurnstile(solveTimeout: TimeInterval, retryTimeout: TimeInterval) async throws {
        guard try await evaluateBool("document.querySelector('.cf-turnstile') !== null") else {
            return
        }

        if await attemptTurnstileSolve(timeout: solveTimeout) {
            return
        }

        _ = try await connection.call("Page.reload", params: [:])
        try await waitForDocumentReady(timeout: retryTimeout)
        _ = await attemptTurnstileSolve(timeout: solveTimeout)
    }

    func cookies() async throws -> [BrowserCookie] {
        let payload = try jsonDictionary(from: try await connection.call("Network.getCookies", params: [:]))
        let cookies = payload["cookies"] as? [[String: Any]] ?? []
        return cookies.compactMap { cookie in
            guard
                let name = cookie["name"] as? String,
                let value = cookie["value"] as? String,
                let domain = cookie["domain"] as? String
            else {
                return nil
            }
            return BrowserCookie(name: name, value: value, domain: domain)
        }
    }

    func fetchTextResource(at url: URL, timeout: TimeInterval) async throws -> String {
        let urlLiteral = quotedJavaScriptLiteral(url.absoluteString)
        let script = """
        (async () => {
          const controller = new AbortController();
          const timeoutId = setTimeout(() => controller.abort(new Error("Pollux playlist fetch timed out")), \(Int(timeout * 1000)));
          try {
            const response = await fetch(\(urlLiteral), { signal: controller.signal });
            clearTimeout(timeoutId);
            return await response.text();
          } catch (error) {
            clearTimeout(timeoutId);
            return "ERROR: " + error.toString();
          }
        })()
        """
        return try await evaluateString(script) ?? ""
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true

        await connection.close()
        ChromiumProcessTracker.shared.terminateSession(id: id)
    }

    private func configure(profile: BrowserProfile) async throws {
        _ = try await connection.call("Page.enable", params: [:])
        _ = try await connection.call("Runtime.enable", params: [:])
        _ = try await connection.call("Network.enable", params: [:])
        _ = try await connection.call("Page.addScriptToEvaluateOnNewDocument", params: [
            "source": profile.stealthScript,
        ])
        _ = try await connection.call("Emulation.setUserAgentOverride", params: [
            "userAgent": profile.userAgent,
            "acceptLanguage": profile.acceptLanguage,
            "platform": profile.platform,
        ])
    }

    func waitForDocumentReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let readyState = try await evaluateString("document.readyState"),
               readyState == "interactive" || readyState == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw PolluxError.browserDidNotExposeDevTools
    }

    private func attemptTurnstileSolve(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var clicked = false

        while Date() < deadline {
            do {
                if try await evaluateBool(ChromeBrowserSession.turnstileGoneScript) {
                    return true
                }

                if !clicked, let point = try await evaluatePoint(ChromeBrowserSession.turnstilePositionScript) {
                    try await click(x: point.x, y: point.y)
                    clicked = true
                }
            } catch {
                return false
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return false
            }
        }

        return (try? await evaluateBool(ChromeBrowserSession.turnstileGoneScript)) ?? false
    }

    func evaluateString(_ script: String) async throws -> String? {
        let value = try await evaluate(script)
        return try cast(value, to: String.self)
    }

    private func evaluateBool(_ script: String) async throws -> Bool {
        let value = try await evaluate(script)
        return try cast(value, to: Bool.self) ?? false
    }

    private func evaluatePoint(_ script: String) async throws -> (x: Double, y: Double)? {
        let value = try await evaluate(script)
        guard let dictionary = try cast(value, to: [String: Double].self),
              let x = dictionary["x"],
              let y = dictionary["y"]
        else {
            return nil
        }
        return (x, y)
    }

    private func evaluate(_ script: String) async throws -> Any? {
        let payload = try await connection.call("Runtime.evaluate", params: [
            "expression": script,
            "awaitPromise": true,
            "returnByValue": true,
        ])
        let result = try jsonDictionary(from: payload)

        if let exception = result["exceptionDetails"] as? [String: Any],
           let text = exception["text"] as? String {
            throw PolluxError.unexpected(text)
        }

        guard let remoteObject = result["result"] as? [String: Any] else {
            return nil
        }
        if remoteObject["type"] as? String == "undefined" {
            return nil
        }
        if remoteObject["subtype"] as? String == "null" {
            return nil
        }
        return remoteObject["value"]
    }

    private func cast<T: Decodable>(_ value: Any?, to type: T.Type) throws -> T? {
        guard let value else {
            return nil
        }
        let wrapped = ["value": value]
        let data = try JSONSerialization.data(withJSONObject: wrapped, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(Wrapper<T>.self, from: data).value
    }
}

private actor CaptureCollector {
    private struct Candidate {
        var rawURL: String
        var headers: [String: String]
        var mimeType: String?
        var score: Int
    }

    private let patterns: [NSRegularExpression]
    private let maxCandidates: Int
    private var candidates: [String: Candidate] = [:]
    private var requestHeadersByID: [String: [String: String]] = [:]

    init(patterns: [String], maxCandidates: Int) {
        self.patterns = patterns.map(NSRegularExpression.init)
        self.maxCandidates = maxCandidates
    }

    func handleEvent(method: String, paramsData: Data) {
        guard let params = try? jsonDictionary(from: paramsData) else {
            return
        }

        switch method {
        case "Network.requestWillBeSent":
            let requestID = params["requestId"] as? String
            let request = params["request"] as? [String: Any]
            let url = request?["url"] as? String
            let headers = headerMap(from: request?["headers"])
            if let requestID {
                requestHeadersByID[requestID] = headers
            }
            if let url {
                print("[CDP Request] \(url)")
                add(url: url, headers: headers, mimeType: nil, requirePatternMatch: true)
            }

        case "Network.responseReceived":
            let requestID = params["requestId"] as? String
            let response = params["response"] as? [String: Any]
            let url = response?["url"] as? String
            let mimeType = response?["mimeType"] as? String
            let headers = requestID.flatMap { requestHeadersByID[$0] } ?? headerMap(from: response?["requestHeaders"])
            if let url {
                add(url: url, headers: headers, mimeType: mimeType, requirePatternMatch: false)
            }

        case "Runtime.consoleAPICalled":
            let args = params["args"] as? [[String: Any]] ?? []
            for argument in args {
                let rawValue = argument["value"] as? String ?? argument["description"] as? String ?? ""
                for capturedURL in m3u8Regex.matches(in: rawValue) {
                    add(url: capturedURL, headers: [:], mimeType: nil, requirePatternMatch: true)
                }
            }

        default:
            return
        }
    }

    func hasHits() -> Bool {
        !candidates.isEmpty
    }

    func waitForEntries(graceAfterActions: TimeInterval, collectionWindow: TimeInterval) async -> [CapturedEntry] {
        if !candidates.isEmpty {
            return await collectMore(for: collectionWindow)
        }

        let graceDeadline = Date().addingTimeInterval(graceAfterActions)
        while Date() < graceDeadline {
            if !candidates.isEmpty {
                return await collectMore(for: collectionWindow)
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return entries()
            }
        }

        return entries()
    }

    private func collectMore(for collectionWindow: TimeInterval) async -> [CapturedEntry] {
        let deadline = Date().addingTimeInterval(collectionWindow)
        while Date() < deadline {
            if hasMasterPlaylist() {
                return entries()
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return entries()
            }
        }
        return entries()
    }

    private func entries() -> [CapturedEntry] {
        candidates.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.rawURL < rhs.rawURL
            }
            .map {
                CapturedEntry(rawURL: $0.rawURL, headers: $0.headers, mimeType: $0.mimeType, score: $0.score)
            }
    }

    private func add(url: String, headers: [String: String], mimeType: String?, requirePatternMatch: Bool) {
        let normalizedMimeType = mimeType?.lowercased()
        if requirePatternMatch && !matchesPattern(url) {
            return
        }
        if !requirePatternMatch && normalizedMimeType.flatMap(StreamKind.fromMIME) == nil {
            return
        }

        if var existing = candidates[url] {
            if existing.mimeType == nil {
                existing.mimeType = normalizedMimeType
            }
            if existing.headers.isEmpty, !headers.isEmpty {
                existing.headers = headers
            }
            existing.score = max(existing.score, rankURL(url))
            candidates[url] = existing
            return
        }

        guard candidates.count < maxCandidates else {
            return
        }

        candidates[url] = Candidate(
            rawURL: url,
            headers: headers,
            mimeType: normalizedMimeType,
            score: rankURL(url)
        )
    }

    private func matchesPattern(_ url: String) -> Bool {
        let stripped = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let nsRange = NSRange(location: 0, length: (stripped as NSString).length)
        return patterns.contains { expression in
            expression.firstMatch(in: stripped, range: nsRange) != nil
        }
    }

    private func hasMasterPlaylist() -> Bool {
        candidates.values.contains(where: { $0.score >= 100 })
    }

    private func rankURL(_ rawURL: String) -> Int {
        guard let parsed = URL(string: rawURL) else {
            return 0
        }
        let path = parsed.path.lowercased()
        var score = 0

        if path.contains("master") {
            score += 100
        }
        if path.contains("playlist") {
            score += 50
        }
        for pattern in ["/720p/", "/1080p/", "/480p/", "/360p/", "/240p/", "/chunklist", "/media-", "/segment"] {
            if path.contains(pattern) {
                score -= 50
                break
            }
        }

        return score
    }
}

private actor CDPConnection {
    private let session: URLSession
    private let webSocket: URLSessionWebSocketTask
    private var pendingCalls: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextIdentifier = 1
    private var receiveTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (String, Data) async -> Void)?
    private var isClosed = false

    init(webSocketURL: URL) {
        self.session = URLSession(configuration: .ephemeral)
        self.webSocket = session.webSocketTask(with: webSocketURL)
        self.webSocket.resume()
    }

    func start() {
        guard receiveTask == nil else {
            return
        }
        receiveTask = Task {
            await self.receiveLoop()
        }
    }

    func setEventHandler(_ eventHandler: @escaping @Sendable (String, Data) async -> Void) {
        self.eventHandler = eventHandler
    }

    func call(_ method: String, params: [String: Any]) async throws -> Data {
        guard !isClosed else {
            throw PolluxError.browserDidNotExposeDevTools
        }

        let identifier = nextIdentifier
        nextIdentifier += 1

        let payload: [String: Any] = [
            "id": identifier,
            "method": method,
            "params": params,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let message = String(decoding: encoded, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[identifier] = continuation
            Task {
                do {
                    try await webSocket.send(.string(message))
                } catch {
                    failPendingCall(id: identifier, error: error)
                }
            }
        }
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        receiveTask?.cancel()
        webSocket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()

        let error = PolluxError.browserDidNotExposeDevTools
        let pending = pendingCalls
        pendingCalls.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    private func receiveLoop() async {
        while !isClosed {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .data(let data):
                    try await handleMessage(data)
                case .string(let string):
                    try await handleMessage(Data(string.utf8))
                @unknown default:
                    continue
                }
            } catch {
                if !isClosed {
                    failAllPending(error: error)
                }
                return
            }
        }
    }

    private func handleMessage(_ data: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return
        }

        if let identifier = object["id"] as? Int {
            guard let continuation = pendingCalls.removeValue(forKey: identifier) else {
                return
            }

            if let errorPayload = object["error"] as? [String: Any] {
                let message = errorPayload["message"] as? String ?? "Chrome DevTools command failed."
                continuation.resume(throwing: PolluxError.unexpected(message))
                return
            }

            let resultObject = object["result"] ?? [:]
            let resultData = try JSONSerialization.data(withJSONObject: resultObject, options: [.fragmentsAllowed])
            continuation.resume(returning: resultData)
            return
        }

        guard let method = object["method"] as? String else {
            return
        }

        let paramsObject = object["params"] ?? [:]
        let paramsData = try JSONSerialization.data(withJSONObject: paramsObject, options: [.fragmentsAllowed])
        if let eventHandler {
            await eventHandler(method, paramsData)
        }
    }

    private func failPendingCall(id: Int, error: Error) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failAllPending(error: Error) {
        isClosed = true
        let pending = pendingCalls
        pendingCalls.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}

private struct DevToolsTarget: Decodable {
    let type: String
    let webSocketDebuggerURL: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}

private struct Wrapper<Value: Decodable>: Decodable {
    let value: Value
}

private final class ChromeLaunchDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    init(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, toStandardError: false)
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, toStandardError: true)
        }
    }

    func stop() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
    }

    func failureReason(fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let stderr = String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }

        let stdout = String(decoding: stdoutBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }

        return fallback
    }

    private func append(_ data: Data, toStandardError: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if toStandardError {
            stderrBuffer.append(data)
            trim(&stderrBuffer)
        } else {
            stdoutBuffer.append(data)
            trim(&stdoutBuffer)
        }
    }

    private func trim(_ buffer: inout Data) {
        let maxBytes = 4096
        if buffer.count > maxBytes {
            buffer.removeFirst(buffer.count - maxBytes)
        }
    }
}

private let m3u8Regex = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+\.m3u8[^\s"'<>]*"#)

private extension NSRegularExpression {
    convenience init(_ pattern: String) {
        try! self.init(pattern: pattern)
    }

    func matches(in text: String) -> [String] {
        let nsText = text as NSString
        let results = matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return results.map { nsText.substring(with: $0.range) }
    }
}

private func waitForDebugPort(
    process: Process,
    diagnostics: ChromeLaunchDiagnostics,
    userDataDirectory: URL,
    timeout: TimeInterval
) async throws -> Int {
    let portFile = userDataDirectory.appendingPathComponent("DevToolsActivePort")
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if let contents = try? String(contentsOf: portFile, encoding: .utf8) {
            let lines = contents
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            if let portString = lines.first, let port = Int(portString) {
                return port
            }
        }

        if !process.isRunning {
            throw PolluxError.browserLaunchFailed(
                diagnostics.failureReason(fallback: "Chromium exited before Pollux could attach to its DevTools endpoint.")
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
    }

    throw PolluxError.browserLaunchFailed(
        diagnostics.failureReason(fallback: "Timed out waiting for Chromium's DevTools port.")
    )
}

private func waitForPageSocketURL(
    port: Int,
    diagnostics: ChromeLaunchDiagnostics,
    timeout: TimeInterval
) async throws -> URL {
    let deadline = Date().addingTimeInterval(timeout)
    let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list")!
    let createEndpoint = URL(string: "http://127.0.0.1:\(port)/json/new?about:blank")!
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var attemptedTargetCreation = false

    while Date() < deadline {
        do {
            let targets = try await fetchDevToolsTargets(from: endpoint, using: session)
            if let socketURL = targets.first(where: { $0.type == "page" })?.webSocketDebuggerURL {
                return socketURL
            }

            if !attemptedTargetCreation,
               let createdTarget = try await createDevToolsTarget(at: createEndpoint, using: session) {
                return createdTarget
            }
            attemptedTargetCreation = true
        } catch {
            // Keep retrying while Chromium is still warming up.
        }

        try await Task.sleep(nanoseconds: 100_000_000)
    }

    throw PolluxError.browserLaunchFailed(
        diagnostics.failureReason(fallback: "Chromium started, but it never exposed a page debugging target.")
    )
}

private func fetchDevToolsTargets(from endpoint: URL, using session: URLSession) async throws -> [DevToolsTarget] {
    let (data, _) = try await session.data(from: endpoint)
    return try JSONDecoder().decode([DevToolsTarget].self, from: data)
}

private func createDevToolsTarget(at endpoint: URL, using session: URLSession) async throws -> URL? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "PUT"
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
        return nil
    }
    return try JSONDecoder().decode(DevToolsTarget.self, from: data).webSocketDebuggerURL
}

private func jsonDictionary(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
        return [:]
    }
    return object
}

private func quotedJavaScriptLiteral(_ string: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [string])
    let encoded = String(decoding: data, as: UTF8.self)
    return encoded.dropFirst().dropLast().description
}

private func headerMap(from rawHeaders: Any?) -> [String: String] {
    guard let rawHeaders = rawHeaders as? [String: Any] else {
        return [:]
    }

    var headers: [String: String] = [:]
    for (name, value) in rawHeaders {
        if let stringValue = value as? String {
            headers[name] = stringValue
        } else {
            headers[name] = String(describing: value)
        }
    }
    return headers
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw PolluxError.unexpected("Stream extraction timed out after \(Int(seconds)) seconds.")
        }

        guard let value = try await group.next() else {
            throw PolluxError.unexpected("Stream extraction failed before returning a result.")
        }
        group.cancelAll()
        return value
    }
}
