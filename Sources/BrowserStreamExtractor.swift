import AppKit
import Foundation

final class BrowserStreamExtractor: @unchecked Sendable {
    private let settings = ExtractionSettings()

    func extractPlayableStream(
        from sourcePageURL: URL,
        onProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> ExtractedStream {
        onProgress?("Launching browser...", 0.10)
        let verboseLogging = UserDefaults.standard.bool(forKey: PolluxPreferences.verboseExtractionLoggingKey)
        Task { @MainActor in
            ExtractionLogger.shared.clear()
            ExtractionLogger.shared.append("Starting stream extraction for \(sourcePageURL.absoluteString)")
            if !verboseLogging {
                ExtractionLogger.shared.append("Verbose CDP network logging is off. Enable it in Settings for a full request trace.")
            }
        }

        let profile = BrowserProfile.random()
        let collector = CaptureCollector(patterns: settings.capturePatterns, maxCandidates: settings.maxCandidates)
        let session = try await ChromeBrowserSession.launch(profile: profile) { method, params in
            await collector.handleEvent(method: method, paramsData: params)
            // The collector above must see every event; the per-event log lines below are the noisy
            // part and are only emitted in verbose mode.
            guard verboseLogging else { return }
            if method == "Network.requestWillBeSent",
               let dict = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
               let req = dict["request"] as? [String: Any],
               let url = req["url"] as? String,
               !url.hasSuffix(".png"), !url.hasSuffix(".jpg"), !url.hasSuffix(".svg"), !url.hasSuffix(".css"), !url.hasSuffix(".woff2") {
                Task { @MainActor in
                    ExtractionLogger.shared.append("CDP Request: \(url)")
                }
            } else if method == "Network.responseReceived",
                      let dict = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
                      let response = dict["response"] as? [String: Any],
                      let url = response["url"] as? String,
                      let status = response["status"] as? Int,
                      !url.hasSuffix(".png"), !url.hasSuffix(".jpg"), !url.hasSuffix(".svg"), !url.hasSuffix(".css"), !url.hasSuffix(".woff2") {
                Task { @MainActor in
                    ExtractionLogger.shared.append("CDP Response [\(status)]: \(url)")
                }
            } else if method == "Runtime.consoleAPICalled",
                      let dict = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
                      let type = dict["type"] as? String {
                Task { @MainActor in
                    ExtractionLogger.shared.append("Console [\(type)]: \(dict["args"] ?? "")")
                }
            }
        }

        // Read the retry budget per-extraction so changing it in Settings takes effect on the next run.
        let extractionTimeout = CaptureRetryBudget.resolved()
        do {
            let overallDeadline = Date().addingTimeInterval(extractionTimeout)
            return try await withTimeout(seconds: extractionTimeout) { [self] in
                try Task.checkCancellation()
                onProgress?("Navigating to target page...", 0.25)
                do {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("Navigating browser to \(sourcePageURL.absoluteString)...")
                    }
                    try await session.navigate(to: sourcePageURL, timeout: self.settings.browserTimeout)
                } catch {
                    if !(await collector.hasHits()) {
                        Task { @MainActor in
                            ExtractionLogger.shared.append("Navigation error: \(error.localizedDescription)")
                        }
                        throw error
                    }
                }

                try Task.checkCancellation()
                onProgress?("Inspecting player & searching streams...", 0.45)
                try await self.runActionPipeline(
                    session: session,
                    collector: collector,
                    profile: profile,
                    deadline: overallDeadline.addingTimeInterval(-25),
                    sourcePageURL: sourcePageURL
                )

                try Task.checkCancellation()
                onProgress?("Capturing network media requests...", 0.70)
                let entries = await collector.waitForEntries(
                    graceAfterActions: self.settings.graceAfterActions,
                    collectionWindow: self.settings.collectionWindow
                )
                guard !entries.isEmpty else {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("No matching media stream requests captured.")
                    }
                    throw PolluxError.noStreamCaptured(sourcePageURL)
                }

                try Task.checkCancellation()
                Task { @MainActor in
                    ExtractionLogger.shared.append("Captured \(entries.count) media candidate request(s). Fetching cookies and playlists...")
                }

                let cookies = try await session.cookies()
                Task { @MainActor in
                    ExtractionLogger.shared.append("Captured cookies: \(cookies.map { "\($0.name)=\($0.value) (\($0.domain))" })")
                }
                let cachedPlaylists = await self.cachePlaylists(from: entries, session: session)
                let candidates = self.buildCandidates(
                    from: entries,
                    cachedPlaylists: cachedPlaylists,
                    cookies: cookies,
                    sourcePageURL: sourcePageURL,
                    userAgent: profile.userAgent
                )
                guard !candidates.isEmpty else {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("No valid candidates constructed from network entries.")
                    }
                    throw PolluxError.noStreamCaptured(sourcePageURL)
                }

                try Task.checkCancellation()
                onProgress?("Validating candidate with ffprobe...", 0.85)
                Task { @MainActor in
                    ExtractionLogger.shared.append("Validating candidates with ffprobe...")
                }

                let selection = try await self.selectBestCandidate(from: candidates, session: session, cachedPlaylists: cachedPlaylists)

                try Task.checkCancellation()
                onProgress?("Preparing playback...", 0.95)
                Task { @MainActor in
                    ExtractionLogger.shared.append("SUCCESS: Selected stream (\(selection.kind)) at \(selection.candidate.url.absoluteString)")
                }

                // Stop collecting/logging CDP events before playback begins. The session normally
                // stays alive for live playlist refresh, but the running player would otherwise flood
                // the logger and freeze the UI.
                await session.detachEventHandler()

                // Opt-in aggressive cleanup: tear the browser down immediately once a stream is
                // selected. Playback then refreshes live playlists over direct connections only.
                let releaseBrowser = UserDefaults.standard.bool(forKey: PolluxPreferences.releaseBrowserAfterExtractionKey)
                if releaseBrowser {
                    await session.close()
                    Task { @MainActor in
                        ExtractionLogger.shared.append("Released extraction browser after selection (per settings).")
                    }
                }

                return ExtractedStream(
                    sourcePageURL: sourcePageURL,
                    streamURL: selection.candidate.url,
                    headers: selection.candidate.headers,
                    kind: selection.kind,
                    cachedPlaylists: cachedPlaylists,
                    excludedVariantURLs: selection.excludedVariantURLs,
                    notice: selection.notice,
                    session: releaseBrowser ? nil : session
                )
            }
        } catch is CancellationError {
            await session.close()
            Task { @MainActor in
                ExtractionLogger.shared.append("Stream extraction was cancelled.")
            }
            throw CancellationError()
        } catch is TimeoutError {
            await session.close()
            Task { @MainActor in
                ExtractionLogger.shared.append("Extraction timed out after \(Int(extractionTimeout)) seconds.")
            }
            throw PolluxError.extractionTimedOut(sourcePageURL, extractionTimeout)
        } catch {
            await session.close()
            Task { @MainActor in
                ExtractionLogger.shared.append("Extraction failed: \(error.localizedDescription)")
            }
            if let polluxError = error as? PolluxError {
                throw polluxError
            }
            throw PolluxError.unexpected(error.localizedDescription)
        }
    }

    private func runActionPipeline(
        session: ChromeBrowserSession,
        collector: CaptureCollector,
        profile: BrowserProfile,
        deadline: Date,
        sourcePageURL: URL
    ) async throws {
        Task { @MainActor in
            ExtractionLogger.shared.append("Starting player interaction pipeline...")
        }

        // Some anti-bot pages serve a blank/broken document to headless automation on most loads,
        // and only occasionally render the real player. Re-navigating gives another independent shot
        // at a good load within the extraction window. Bounded by a cooldown so each load gets a fair
        // chance before we retry.
        var consecutiveBlankProbes = 0
        var lastReload = Date()
        var reloadCount = 0
        let pipelineStart = Date()

        // Autoplay grace: wait briefly for the stream to load on its own before any synthetic click.
        // Chromium runs with --autoplay-policy=no-user-gesture-required, so many players auto-load
        // their HLS. On sites that hijack the first click (popunder/redirect), clicking the content
        // page prematurely navigates it away and blanks the player before it ever appears — so an
        // early click actively prevents capture. Clicking still happens below if this grace lapses.
        let graceDeadline = Date().addingTimeInterval(min(settings.autoplayGrace, max(deadline.timeIntervalSinceNow - 1, 0)))
        while Date() < graceDeadline {
            try Task.checkCancellation()
            if await collector.hasHits() {
                Task { @MainActor in
                    ExtractionLogger.shared.append("Media candidate captured during autoplay grace period (no click needed).")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        while Date() < deadline {
            try Task.checkCancellation()
            if await collector.hasHits() {
                Task { @MainActor in
                    ExtractionLogger.shared.append("Media candidate captured: proceeding to validate.")
                }
                return
            }

            // Probe page state using CDP DOM domain (doesn't require JS main thread)
            var jsMainThreadBlocked = false
            do {
                let domSummaryScript = """
                (() => {
                  const iframes = Array.from(document.querySelectorAll('iframe')).map(i => i.src || i.getAttribute('data-src') || 'no-src');
                  const videos = document.querySelectorAll('video').length;
                  const title = document.title;
                  const bodyText = (document.body && document.body.innerText || '').substring(0, 200);
                  return 'readyState=' + document.readyState + ', title=' + title + ', iframes=' + iframes.length + ' [' + iframes.slice(0, 3).join(', ') + '], videos=' + videos + ', body=' + bodyText;
                })()
                """
                if let summary = try await session.evaluateString(domSummaryScript) {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("DOM State: \(summary)")
                    }
                }
            } catch {
                jsMainThreadBlocked = true
                Task { @MainActor in
                    ExtractionLogger.shared.append("JS main thread blocked (eval timeout). Capturing screenshot...")
                }
                // Fallback: take a screenshot (compositor-level, no JS needed)
                if let screenshotPath = try? await session.captureScreenshot() {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("Screenshot saved: \(screenshotPath)")
                    }
                }
            }

            // Blank-page recovery: if the document loaded but rendered no player/content, the site
            // likely served the anti-bot blank page. Re-navigate to try for a good load. A cooldown
            // ensures the fresh load has time to settle before we judge it blank again.
            if !jsMainThreadBlocked, await session.pageLooksBlank() {
                consecutiveBlankProbes += 1
                let cooldownElapsed = Date().timeIntervalSince(lastReload) > settings.blankPageReloadCooldown
                if consecutiveBlankProbes >= 2, cooldownElapsed, deadline.timeIntervalSinceNow > settings.blankPageReloadCooldown {
                    reloadCount += 1
                    let attempt = reloadCount
                    Task { @MainActor in
                        ExtractionLogger.shared.append("Page looks blank (likely anti-bot). Re-navigating for a fresh load (attempt \(attempt))...")
                    }
                    try? await session.navigate(to: sourcePageURL, timeout: min(settings.browserTimeout, 8))
                    lastReload = Date()
                    consecutiveBlankProbes = 0
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
            } else {
                consecutiveBlankProbes = 0
            }

            // Step 1: Check for Cloudflare Turnstile challenge (skip if JS thread is blocked)
            if !jsMainThreadBlocked {
                try? await session.bypassTurnstile(
                    solveTimeout: settings.turnstileSolveTimeout,
                    retryTimeout: settings.turnstileRetryTimeout
                )
            }

            if await collector.hasHits() {
                Task { @MainActor in
                    ExtractionLogger.shared.append("Media candidate captured after Turnstile check.")
                }
                return
            }

            // Step 2: As a FALLBACK, navigate the top tab into the largest iframe. This is deferred:
            // Chromium runs with site-per-process disabled, so sub-frame network traffic is already
            // captured in place. Many embeds build their real player as a nested iframe from tokens
            // the parent page injects (csrf/sec_hash/pid); navigating the top tab directly into the
            // embed discards that parent context and breaks player creation. So we let in-place clicks
            // start the player first, and only navigate into the iframe if nothing was captured after
            // a grace window.
            if !jsMainThreadBlocked,
               Date().timeIntervalSince(pipelineStart) >= settings.iframeNavigationDelay {
                if let iframeSource = await session.pollForIframeSource(timeout: 2.0),
                   let iframeURL = safeURL(from: iframeSource) {
                    if iframeURL != session.currentURL {
                        Task { @MainActor in
                            ExtractionLogger.shared.append("No stream captured in place; navigating into player iframe: \(iframeURL.absoluteString)")
                        }
                        try? await session.navigate(to: iframeURL, referrer: session.currentURL?.absoluteString, timeout: 5)
                    }
                }

                if await collector.hasHits() {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("Media candidate captured inside iframe.")
                    }
                    return
                }
            }

            // Step 3: Viewport click (works via CDP Input domain, no JS needed)
            Task { @MainActor in
                ExtractionLogger.shared.append("Clicking player viewport center (x: \(profile.centerX), y: \(profile.centerY))...")
            }
            try? await session.click(x: profile.centerX, y: profile.centerY)

            if await collector.hasHits() {
                Task { @MainActor in
                    ExtractionLogger.shared.append("Media candidate captured after viewport click.")
                }
                return
            }

            // Step 4: HTML5 play controls (skip if JS blocked, uses evaluate)
            if !jsMainThreadBlocked {
                Task { @MainActor in
                    ExtractionLogger.shared.append("Querying and clicking HTML5 play controls...")
                }
                await session.clickPlayButtons()

                if await collector.hasHits() {
                    Task { @MainActor in
                        ExtractionLogger.shared.append("Media candidate captured after clicking play controls.")
                    }
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func cachePlaylists(from entries: [CapturedEntry], session: ChromeBrowserSession) async -> [String: String] {
        var cachedPlaylists: [String: String] = [:]
        var pendingURLs = entries.compactMap { entry -> URL? in
            guard let url = safeURL(from: entry.rawURL),
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
                let url = safeURL(from: entry.rawURL),
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
                let url = safeURL(from: cachedPlaylistURL),
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
        session: ChromeBrowserSession,
        cachedPlaylists: [String: String]
    ) async throws -> CandidateSelection {
        let prober = try FFprobeService()

        let evaluations = await withTaskGroup(of: ProbeEvaluation.self, returning: [ProbeEvaluation].self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let result = try await probeCandidate(candidate, with: prober, session: session, cachedPlaylists: cachedPlaylists)
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

        var playable: [(candidate: StreamCandidate, kind: StreamKind, bitRate: Int64, notice: String?)] = []
        var fallbacks: [StreamCandidate] = []
        var unsupportedKinds = Set<String>()
        var excludedVariantURLs = Set<String>()

        for evaluation in evaluations {
            switch evaluation {
            case .success(let candidate, let result):
                let resolvedKind = result.kind ?? candidate.kind
                if !resolvedKind.avPlayerSupported {
                    unsupportedKinds.insert(resolvedKind.displayName)
                    continue
                }
                if acceptsProbeResult(result, for: resolvedKind) {
                    playable.append((candidate, resolvedKind, max(result.bitRate, 1), probeResultNotice(result, for: resolvedKind)))
                } else if resolvedKind == .hls {
                    excludedVariantURLs.insert(candidate.url.absoluteString)
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
            : playable.filter { entry in
                preferredPlayableCandidates.contains { $0.url == entry.candidate.url }
            }

        if let bestPlayable = playablePool.max(by: { lhs, rhs in
            if lhs.bitRate != rhs.bitRate {
                return lhs.bitRate < rhs.bitRate
            }
            return lhs.candidate.score < rhs.candidate.score
        }) {
            return CandidateSelection(
                candidate: bestPlayable.candidate,
                kind: bestPlayable.kind,
                excludedVariantURLs: excludedVariantURLs,
                notice: bestPlayable.notice
            )
        }

        if let masterFallback = bestMasterPlaylistCandidate(from: candidates, cachedPlaylists: cachedPlaylists) {
            return CandidateSelection(
                candidate: masterFallback,
                kind: .hls,
                excludedVariantURLs: excludedVariantURLs,
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
                excludedVariantURLs: excludedVariantURLs,
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
    session: ChromeBrowserSession,
    cachedPlaylists: [String: String]
) async throws -> ProbeResult {
    guard candidate.kind == .hls else {
        return try await prober.probe(candidate: candidate)
    }

    do {
        return try await probeHLSCandidateThroughProxy(candidate, with: prober, session: session, cachedPlaylists: cachedPlaylists)
    } catch {
        return try await prober.probe(candidate: candidate)
    }
}

private func probeHLSCandidateThroughProxy(
    _ candidate: StreamCandidate,
    with prober: FFprobeService,
    session: ChromeBrowserSession,
    cachedPlaylists: [String: String]
) async throws -> ProbeResult {
    let extracted = ExtractedStream(
        sourcePageURL: candidate.url,
        streamURL: candidate.url,
        headers: candidate.headers,
        kind: candidate.kind,
        cachedPlaylists: cachedPlaylists,
        excludedVariantURLs: [],
        notice: nil,
        session: session
    )
    // Borrow the shared browser session for validation only. Stopping this proxy must NOT close the
    // session — the playback proxy still needs it alive to refresh the live playlist.
    let proxy = try StreamProxyServer(stream: extracted, ownsSession: false)

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
    let autoplayGrace: TimeInterval = 6
    let iframeNavigationDelay: TimeInterval = 14
    let blankPageReloadCooldown: TimeInterval = 6
    let graceAfterActions: TimeInterval = 15
    let collectionWindow: TimeInterval = 10
    let playlistFetchTimeout: TimeInterval = 6
    let maxCachedPlaylists = 12
    let navigateIframeTimeout: TimeInterval = 10
    let navigateIframeMaxDepth = 5
    let turnstileSolveTimeout: TimeInterval = 3
    let turnstileRetryTimeout: TimeInterval = 2
    let capturePatterns = [
        #"\.m3u8"#,
        #"master\.m3u8"#,
        #"index\.m3u8"#,
        #"/playlist"#,
        #"/manifest"#,
        #"/hls[/.]"#,
        #"\.mp4"#,
        #"/streams?/"#,
        #"/live/"#,
        #"/chunklist"#,
        #"\.ts$"#,
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
          const patch = (target, key, value) => {
            try {
              Object.defineProperty(target, key, {
                get: () => value,
                configurable: true
              });
            } catch(e) {}
          };
          patch(navigator, 'webdriver', false);
          patch(navigator, 'hardwareConcurrency', 8);
          patch(navigator, 'deviceMemory', 8);
          patch(navigator, 'platform', '\(platform)');
          patch(navigator, 'languages', ['en-US', 'en']);

          window.chrome = window.chrome || {
            app: { isInstalled: false },
            runtime: {
              OnInstalledReason: { INSTALL: "install", UPDATE: "update" },
              OnRestartRequiredReason: { APP_UPDATE: "app_update" },
              PlatformArch: { ARM64: "arm64", X86_64: "x86-64" },
              PlatformOs: { MAC: "mac", WIN: "win" }
            },
            csi: function() {},
            loadTimes: function() {}
          };

          try {
            const getParameter = WebGLRenderingContext.prototype.getParameter;
            WebGLRenderingContext.prototype.getParameter = function(parameter) {
              if (parameter === 37445) return 'Apple';
              if (parameter === 37446) return 'ANGLE (Apple, Apple M1, OpenGL 4.1)';
              return getParameter.apply(this, arguments);
            };
          } catch(e) {}

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

    /// A stronger stealth bundle used only on the quiet-CDP path. Beyond the baseline patches it fixes
    /// the headless fingerprints anti-bot scripts key on: empty `navigator.plugins`/`mimeTypes`, zeroed
    /// `outerWidth`/`outerHeight`, missing `navigator.connection`, WebGL2, and — importantly — makes the
    /// patched functions report native `toString()` so the overrides themselves can't be detected.
    var hardenedStealthScript: String {
        """
        (() => {
          const nativeToString = Function.prototype.toString;
          const faux = new WeakSet();
          const asNative = (fn) => { try { faux.add(fn); } catch (e) {} return fn; };
          const toStringProxy = function toString() {
            if (faux.has(this)) return 'function ' + (this.name || '') + '() { [native code] }';
            return nativeToString.call(this);
          };
          faux.add(toStringProxy);
          try { Function.prototype.toString = toStringProxy; } catch (e) {}

          const patch = (target, key, getter) => {
            try {
              Object.defineProperty(target, key, { get: asNative(getter), configurable: true });
            } catch (e) {}
          };

          patch(navigator, 'webdriver', () => false);
          patch(navigator, 'hardwareConcurrency', () => 8);
          patch(navigator, 'deviceMemory', () => 8);
          patch(navigator, 'platform', () => '\(platform)');
          patch(navigator, 'languages', () => ['en-US', 'en']);
          patch(navigator, 'maxTouchPoints', () => 0);

          // Real desktop Chrome exposes these; headless zeroes/omits them.
          try {
            patch(window, 'outerWidth', () => \(windowWidth));
            patch(window, 'outerHeight', () => \(windowHeight));
          } catch (e) {}
          try {
            patch(navigator, 'connection', () => ({
              effectiveType: '4g', rtt: 50, downlink: 10, saveData: false
            }));
          } catch (e) {}

          // A non-empty PluginArray/MimeTypeArray — the single most common headless tell.
          try {
            const makePlugin = (name, filename, desc) => {
              const p = Object.create(Plugin.prototype);
              Object.defineProperties(p, {
                name: { value: name }, filename: { value: filename },
                description: { value: desc }, length: { value: 1 }
              });
              return p;
            };
            const plugins = [
              makePlugin('PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
              makePlugin('Chrome PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
              makePlugin('Chromium PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
            ];
            const arr = Object.create(PluginArray.prototype);
            plugins.forEach((p, i) => { arr[i] = p; });
            Object.defineProperty(arr, 'length', { value: plugins.length });
            patch(navigator, 'plugins', () => arr);
            const mimeArr = Object.create(MimeTypeArray.prototype);
            Object.defineProperty(mimeArr, 'length', { value: 1 });
            patch(navigator, 'mimeTypes', () => mimeArr);
          } catch (e) {}

          window.chrome = window.chrome || {
            app: { isInstalled: false },
            runtime: {
              OnInstalledReason: { INSTALL: "install", UPDATE: "update" },
              OnRestartRequiredReason: { APP_UPDATE: "app_update" },
              PlatformArch: { ARM64: "arm64", X86_64: "x86-64" },
              PlatformOs: { MAC: "mac", WIN: "win" }
            },
            csi: asNative(function () {}),
            loadTimes: asNative(function () {})
          };

          const spoofWebGL = (proto) => {
            try {
              const getParameter = proto.prototype.getParameter;
              proto.prototype.getParameter = asNative(function (parameter) {
                if (parameter === 37445) return 'Apple';
                if (parameter === 37446) return 'ANGLE (Apple, Apple M1, OpenGL 4.1)';
                return getParameter.apply(this, arguments);
              });
            } catch (e) {}
          };
          spoofWebGL(WebGLRenderingContext);
          if (typeof WebGL2RenderingContext !== 'undefined') spoofWebGL(WebGL2RenderingContext);

          const originalQuery = navigator.permissions && navigator.permissions.query;
          if (originalQuery) {
            navigator.permissions.query = asNative((parameters) => {
              if (parameters && parameters.name === 'notifications') {
                return Promise.resolve({ state: Notification.permission });
              }
              return originalQuery.call(navigator.permissions, parameters);
            });
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
    let excludedVariantURLs: Set<String>
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
            }
            // Hard-kill the whole Chromium process tree (main + renderer/gpu/network helpers), which a
            // plain terminate() on the parent does not reliably reap, then delete the profile.
            Self.killProcessTree(userDataDirectory: tracked.userDataDirectory)
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
            Self.killProcessTree(userDataDirectory: tracked.userDataDirectory)
            try? FileManager.default.removeItem(at: tracked.userDataDirectory)
        }
    }

    /// Removes leftover extraction browsers from previous runs (e.g. after a crash or force-quit).
    /// Safe to call at launch — any `pollux-chrome-*` profile in the temp dir is stale because we have
    /// not started a session yet.
    func cleanupOrphans() {
        let tempDirectory = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for entry in entries where entry.lastPathComponent.hasPrefix("pollux-chrome-") {
            Self.killProcessTree(userDataDirectory: entry)
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Kills every process whose command line references this profile directory. The unique UUID in
    /// the path makes the match precise, so unrelated processes are never touched.
    private static func killProcessTree(userDataDirectory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", userDataDirectory.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // pkill unavailable or nothing matched — nothing more to do.
        }
    }
}

final class ChromeBrowserSession: BrowserSession, @unchecked Sendable {
    let id: UUID
    private static let largestIframeScript = """
    (function() {
      const iframes = document.querySelectorAll('iframe');
      let best = null, maxArea = 0;
      for (const f of iframes) {
        let src = f.src || f.getAttribute('data-src') || f.getAttribute('data-url') || f.getAttribute('src') || '';
        if (!src || src.startsWith('about:') || src.startsWith('javascript:')) continue;
        try { src = new URL(src, window.location.href).href; } catch(e) {}
        const r = f.getBoundingClientRect();
        const a = r.width * r.height;
        if (a > maxArea) { maxArea = a; best = src; }
      }
      if (best) return best;
      for (const f of iframes) {
        let src = f.src || f.getAttribute('data-src') || f.getAttribute('data-url') || f.getAttribute('src') || '';
        if (!src || src.startsWith('about:') || src.startsWith('javascript:')) continue;
        try { src = new URL(src, window.location.href).href; } catch(e) {}
        if (src.startsWith('http://') || src.startsWith('https://')) return src;
      }
      return null;
    })()
    """

    private static let turnstilePositionScript = """
    (function() {
        const f = document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"], .cf-turnstile iframe');
        if (!f) return null;
        const r = f.getBoundingClientRect();
        if (r.width < 10 || r.height < 10) return null;
        return {x: Math.round(r.x + Math.min(35, r.width / 2)), y: Math.round(r.y + r.height / 2)};
    })()
    """

    private static let turnstileGoneScript = """
    (function() {
        const resp = document.querySelector('[name="cf-turnstile-response"]');
        if (resp && resp.value && resp.value.length > 0) return true;
        const f = document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"], .cf-turnstile iframe');
        return f === null;
    })()
    """
    private static let startupTimeout: TimeInterval = 30
    private static let targetDiscoveryTimeout: TimeInterval = 15

    private let process: Process
    private let userDataDirectory: URL
    private let connection: CDPConnection
    private var closed = false
    private(set) var currentURL: URL?

    /// Anti-automation mitigation ("quiet CDP") is active for this session. Set once at launch.
    private let mitigation: Bool
    /// Execution context of the isolated world our probes run in when mitigation is active. Recreated
    /// after each navigation (navigation destroys the old world). `nil` means "use the default world",
    /// which is the behavior when mitigation is off or before the first world has been created.
    private var isolatedContextId: Int?

    private init(id: UUID, process: Process, userDataDirectory: URL, connection: CDPConnection, mitigation: Bool) {
        self.id = id
        self.process = process
        self.userDataDirectory = userDataDirectory
        self.connection = connection
        self.mitigation = mitigation
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

        // Headful mode (opt-in): launch a real, visible window instead of headless so sites that
        // detect and block headless Chromium still render their player.
        let headful = UserDefaults.standard.bool(forKey: PolluxPreferences.headfulExtractionKey)
        // Anti-automation mitigation (opt-in "quiet CDP" path): active at the Standard level. The
        // Maximum level never reaches CDP launch — it is routed to the passive net-log capture path.
        let mitigation = AntiAutomationLevel.resolved() == .standard

        process.arguments = launchArguments(
            profile: profile,
            userDataDirectory: userDataDirectory,
            headful: headful,
            mitigation: mitigation
        )

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
                connection: connection,
                mitigation: mitigation
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

    /// Builds the Chromium command-line arguments. Extracted for unit testing so the mitigation and
    /// headful toggles can be verified without launching a real browser.
    static func launchArguments(
        profile: BrowserProfile,
        userDataDirectory: URL,
        headful: Bool,
        mitigation: Bool
    ) -> [String] {
        var arguments = [
            "--remote-debugging-port=0",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-dev-shm-usage",
            "--disable-blink-features=AutomationControlled",
            "--disable-infobars",
            "--use-mock-keychain",
            "--disable-background-timer-throttling",
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--autoplay-policy=no-user-gesture-required",
            "--incognito",
            "--disable-features=IsolateOrigins,site-per-process",
            "--window-size=\(profile.windowWidth),\(profile.windowHeight)",
            "--user-agent=\(profile.userAgent)",
        ]
        // `--disable-web-security` is itself a fingerprint (CORS/SharedArrayBuffer behavior differs from
        // a real browser). In the quiet-CDP path we drop it and instead fetch cross-origin playlists
        // from an isolated world granted universal access, which keeps capture working without the tell.
        if !mitigation {
            arguments.append("--disable-web-security")
        }
        if !headful {
            arguments.append("--headless=new")
        }
        arguments.append("about:blank")
        return arguments
    }

    func navigate(to url: URL, referrer: String? = nil, timeout: TimeInterval) async throws {
        var params: [String: Any] = ["url": url.absoluteString]
        if let referrer {
            params["referrer"] = referrer
        }
        currentURL = url
        // Navigation destroys any isolated world we created for the previous document; fall back to the
        // default world for the readyState probe until we can create a fresh one below.
        isolatedContextId = nil
        _ = try? await connection.call("Page.navigate", params: params, timeout: 10.0)
        do {
            try await waitForDocumentReady(timeout: min(timeout, 8.0))
        } catch {
            Task { @MainActor in
                ExtractionLogger.shared.append("Page ready state check notice: continuing pipeline to inspect player & network candidates.")
            }
        }
        await refreshIsolatedWorld()
    }

    /// Creates a fresh isolated world in the main frame and remembers its execution context so that
    /// subsequent `Runtime.evaluate` calls run there instead of the page's main world. No-op unless
    /// anti-automation mitigation is active. The world is granted universal access so our cross-origin
    /// playlist fetches keep working without `--disable-web-security`.
    private func refreshIsolatedWorld() async {
        guard mitigation else { return }
        do {
            let treePayload = try await connection.call("Page.getFrameTree", params: [:])
            let tree = try jsonDictionary(from: treePayload)
            guard let frameTree = tree["frameTree"] as? [String: Any],
                  let frame = frameTree["frame"] as? [String: Any],
                  let frameId = frame["id"] as? String else {
                isolatedContextId = nil
                return
            }
            let worldPayload = try await connection.call("Page.createIsolatedWorld", params: [
                "frameId": frameId,
                "worldName": "pollux_probe",
                "grantUniveralAccess": true,
            ])
            let world = try jsonDictionary(from: worldPayload)
            isolatedContextId = world["executionContextId"] as? Int
        } catch {
            // If world creation fails we fall back to the default context; probing still works, just
            // without the isolation benefit.
            isolatedContextId = nil
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
                  let iframeURL = safeURL(from: iframeSource)
            else {
                return
            }
            currentURL = iframeURL
            _ = try await connection.call("Page.navigate", params: ["url": iframeURL.absoluteString])
            try await waitForDocumentReady(timeout: min(3, max(deadline.timeIntervalSinceNow, 1)))
        }
    }

    func bypassTurnstile(solveTimeout: TimeInterval, retryTimeout: TimeInterval) async throws {
        let hasTurnstileScript = """
        (function() {
            return document.querySelector('.cf-turnstile, iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"]') !== null;
        })()
        """
        guard try await evaluateBool(hasTurnstileScript) else {
            return
        }

        Task { @MainActor in
            ExtractionLogger.shared.append("Detected Cloudflare Turnstile challenge. Attempting click solve...")
        }
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
            const response = await fetch(\(urlLiteral), {
              signal: controller.signal,
              cache: 'no-store',
              headers: {
                'Cache-Control': 'no-cache, no-store, must-revalidate',
                'Pragma': 'no-cache'
              }
            });
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

    func fetchBinaryResource(at url: URL, timeout: TimeInterval) async throws -> Data {
        let urlLiteral = quotedJavaScriptLiteral(url.absoluteString)
        let script = """
        (async () => {
          const controller = new AbortController();
          const timeoutId = setTimeout(() => controller.abort(new Error("Pollux binary fetch timed out")), \(Int(timeout * 1000)));
          try {
            const response = await fetch(\(urlLiteral), { signal: controller.signal });
            const blob = await response.blob();
            const dataURL = await new Promise((resolve, reject) => {
              const reader = new FileReader();
              reader.onloadend = () => resolve(reader.result || "");
              reader.onerror = () => reject(reader.error || new Error("Failed to read fetched blob"));
              reader.readAsDataURL(blob);
            });
            clearTimeout(timeoutId);
            return dataURL;
          } catch (error) {
            clearTimeout(timeoutId);
            return "ERROR: " + error.toString();
          }
        })()
        """
        let result = try await evaluateString(script) ?? ""
        if result.hasPrefix("ERROR:") {
            throw PolluxError.unexpected(result)
        }
        guard let data = decodeBase64DataURL(result) else {
            throw PolluxError.unexpected("Browser binary fetch returned undecodable data.")
        }
        return data
    }

    /// Silences CDP event delivery (network/console events). Extraction attaches a handler that logs
    /// and collects every network event; once we hand the live session to the playback proxy we must
    /// detach it, otherwise the running player's ongoing network traffic (plus our own proxy fetches)
    /// floods the collector and the @MainActor logger and hangs the app.
    func detachEventHandler() async {
        await connection.setEventHandler { _, _ in }
    }

    /// True when the document has finished loading but has no player, no iframe, and no visible text —
    /// the "blank/broken" state anti-bot pages serve to headless automation. Used to decide whether a
    /// fresh re-navigation is worth attempting.
    func pageLooksBlank() async -> Bool {
        let script = """
        (() => {
          if (document.readyState !== 'complete') return false;
          if (document.querySelector('video') || document.querySelector('iframe')) return false;
          const title = (document.title || '').trim();
          const bodyText = (document.body && document.body.innerText || '').trim();
          return title.length === 0 && bodyText.length === 0;
        })()
        """
        return (try? await evaluateBool(script)) ?? false
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true

        await connection.close()
        ChromiumProcessTracker.shared.terminateSession(id: id)
    }

    /// Get a snippet of the page HTML using CDP DOM domain (bypasses JS main thread).
    func getOuterHTMLSnippet(maxLength: Int = 500) async throws -> String? {
        let docPayload = try await connection.call("DOM.getDocument", params: ["depth": 0], timeout: 3.0)
        let docResult = try jsonDictionary(from: docPayload)
        guard let root = docResult["root"] as? [String: Any],
              let nodeId = root["nodeId"] as? Int else {
            return nil
        }
        let htmlPayload = try await connection.call("DOM.getOuterHTML", params: ["nodeId": nodeId], timeout: 3.0)
        let htmlResult = try jsonDictionary(from: htmlPayload)
        guard let outerHTML = htmlResult["outerHTML"] as? String else {
            return nil
        }
        if outerHTML.count > maxLength {
            return String(outerHTML.prefix(maxLength)) + "..."
        }
        return outerHTML
    }

    /// Capture a screenshot using CDP Page.captureScreenshot (compositor-level, no JS needed).
    func captureScreenshot() async throws -> String {
        let payload = try await connection.call("Page.captureScreenshot", params: [
            "format": "png",
        ], timeout: 5.0)
        let result = try jsonDictionary(from: payload)
        guard let base64Data = result["data"] as? String,
              let imageData = Data(base64Encoded: base64Data) else {
            throw PolluxError.unexpected("Screenshot capture returned no data")
        }
        let screenshotDir = FileManager.default.temporaryDirectory.appendingPathComponent("pollux-screenshots")
        try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
        let filename = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        let filePath = screenshotDir.appendingPathComponent(filename)
        try imageData.write(to: filePath)
        return filePath.path
    }

    private func configure(profile: BrowserProfile) async throws {
        _ = try await connection.call("Page.enable", params: [:])
        // `Runtime.enable` is the loudest CDP tell — it lets a page observe the DevTools console
        // serializer and conclude it is being automated. In the quiet-CDP path we never enable it;
        // `Runtime.evaluate` still works as a command without it, and we run probes in an isolated
        // world so they leave no trace in the page's main world. Cost: console-based m3u8 sniffing is
        // unavailable (Network-domain capture is the primary path anyway).
        if !mitigation {
            _ = try await connection.call("Runtime.enable", params: [:])
        }
        _ = try await connection.call("Network.enable", params: [:])
        _ = try await connection.call("DOM.enable", params: [:])
        _ = try? await connection.call("Emulation.setAutomationOverride", params: ["enabled": false])
        _ = try? await connection.call("Emulation.setFocusEmulationEnabled", params: ["enabled": true])
        _ = try await connection.call("Page.addScriptToEvaluateOnNewDocument", params: [
            "source": mitigation ? profile.hardenedStealthScript : profile.stealthScript,
        ])
        _ = try await connection.call("Emulation.setUserAgentOverride", params: [
            "userAgent": profile.userAgent,
            "acceptLanguage": profile.acceptLanguage,
            "platform": profile.platform,
        ])
    }

    func waitForDocumentReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let checkScript = """
        (() => {
          if (document.readyState === 'interactive' || document.readyState === 'complete') return true;
          if (document.body && (document.querySelector('iframe') || document.querySelector('video') || document.body.children.length > 0)) return true;
          return false;
        })()
        """
        while Date() < deadline {
            try Task.checkCancellation()
            if let isReady = try? await evaluateBool(checkScript), isReady {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let currentURL {
            throw PolluxError.navigationTimedOut(currentURL)
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
        var params: [String: Any] = [
            "expression": script,
            "returnByValue": true,
            "awaitPromise": true,
        ]
        // When mitigation is active, run in the isolated world so nothing we evaluate is visible to the
        // page's main-world code. `contextId` is omitted (default world) when no isolated world exists.
        if let isolatedContextId {
            params["contextId"] = isolatedContextId
        }
        let payload = try await connection.call("Runtime.evaluate", params: params, timeout: 8.0)
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
        self.patterns = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
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
        candidates.values.contains { candidate in
            let path = getPathAndExtension(from: candidate.rawURL).path.lowercased()
            return path.contains(".m3u8") || path.contains(".mp4") || path.contains(".ts") || candidate.score >= 50
        }
    }

    func waitForEntries(graceAfterActions: TimeInterval, collectionWindow: TimeInterval) async -> [CapturedEntry] {
        if hasHits() {
            return await collectMore(for: collectionWindow)
        }

        let graceDeadline = Date().addingTimeInterval(graceAfterActions)
        while Date() < graceDeadline {
            if hasHits() {
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
        Task { @MainActor in
            ExtractionLogger.shared.append("CAPTURED MEDIA CANDIDATE: \(url)")
        }
    }

    private func matchesPattern(_ url: String) -> Bool {
        let parsed = getPathAndExtension(from: url)
        let path = parsed.path
        let nsRange = NSRange(location: 0, length: (path as NSString).length)
        return patterns.contains { expression in
            expression.firstMatch(in: path, range: nsRange) != nil
        }
    }

    private func hasMasterPlaylist() -> Bool {
        candidates.values.contains(where: { $0.score >= 100 })
    }

    private func rankURL(_ rawURL: String) -> Int {
        let parsed = getPathAndExtension(from: rawURL)
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

    func call(_ method: String, params: [String: Any], timeout: TimeInterval = 10.0) async throws -> Data {
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

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    Task {
                        await self.sendAndRegisterCall(id: identifier, message: message, continuation: continuation)
                    }
                }
                return data
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.failPendingCall(id: identifier, error: TimeoutError())
                throw TimeoutError()
            }

            guard let result = try await group.next() else {
                throw PolluxError.unexpected("CDP call \(method) returned no data.")
            }
            group.cancelAll()
            return result
        }
    }

    private func sendAndRegisterCall(id: Int, message: String, continuation: CheckedContinuation<Data, Error>) {
        pendingCalls[id] = continuation
        webSocket.send(.string(message)) { error in
            if let error {
                Task {
                    await self.failPendingCall(id: id, error: error)
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

    private func storePendingCall(id: Int, continuation: CheckedContinuation<Data, Error>) {
        pendingCalls[id] = continuation
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

struct TimeoutError: Error, Sendable {}

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
            throw TimeoutError()
        }

        guard let value = try await group.next() else {
            throw PolluxError.unexpected("Stream extraction failed before returning a result.")
        }
        group.cancelAll()
        return value
    }
}
