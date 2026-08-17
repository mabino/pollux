import AppKit
import Foundation

final class BrowserStreamExtractor: @unchecked Sendable {
    private let settings = ExtractionSettings()

    func extractPlayableStream(
        from sourcePageURL: URL,
        onProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> ExtractedStream {
        onProgress?("Launching browser...", 0.10)
        // Resolve all per-run settings once up front so changes in Settings take effect on the next run
        // and one consistent snapshot is used throughout this extraction.
        let config = ResolvedRunConfig.resolved()
        let verboseLogging = config.verboseLogging
        Task { @MainActor in
            ExtractionLogger.shared.clear()
            ExtractionLogger.shared.append("Starting stream extraction for \(sourcePageURL.absoluteString)")
            if !verboseLogging {
                ExtractionLogger.shared.append("Verbose CDP network logging is off. Enable it in Settings for a full request trace.")
            }
        }

        let profile = BrowserProfile.random()
        let collector = CaptureCollector(patterns: settings.capturePatterns, maxCandidates: settings.maxCandidates)
        // Response-Relay Mode: capture the player's own media responses from the start (so the master
        // playlist, which the player fetches once, is caught), and keep feeding it during playback.
        let relay: MediaRelay? = config.mediaRelay ? MediaRelay(streamHost: nil) : nil
        let session = try await ChromeBrowserSession.launch(profile: profile) { method, params, sessionId in
            await collector.handleEvent(method: method, paramsData: params)
            if let relay {
                await relay.handleEvent(method: method, paramsData: params, sessionId: sessionId)
            }
            // The collector above must see every event; the per-event log lines below are the noisy
            // part and are only emitted in verbose mode.
            guard verboseLogging else { return }
            if method == "Network.requestWillBeSent",
               let dict = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
               let req = dict["request"] as? [String: Any],
               let url = req["url"] as? String,
               !url.hasSuffix(".png"), !url.hasSuffix(".jpg"), !url.hasSuffix(".svg"), !url.hasSuffix(".css"), !url.hasSuffix(".woff2") {
                ExtractionLogger.log("CDP Request: \(url)")
            } else if method == "Network.responseReceived",
                      let dict = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
                      let response = dict["response"] as? [String: Any],
                      let url = response["url"] as? String,
                      let status = response["status"] as? Int,
                      !url.hasSuffix(".png"), !url.hasSuffix(".jpg"), !url.hasSuffix(".svg"), !url.hasSuffix(".css"), !url.hasSuffix(".woff2") {
                ExtractionLogger.log("CDP Response [\(status)]: \(url)")
            } else if method == "Runtime.consoleAPICalled",
                      let dict = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
                      let type = dict["type"] as? String {
                ExtractionLogger.log("Console [\(type)]: \(dict["args"] ?? "")")
            }
        }

        // Give the collector a way to pull API/XHR response bodies now that the session exists. This is
        // what lets it recover a stream URL from a JSON config response when the anti-bot player is
        // handed its config but never issues the media request itself.
        await collector.setBodyFetcher { [session] requestID in
            await session.fetchResponseBody(requestID: requestID)
        }
        // The relay pulls raw bytes (segments are binary) rather than the lossy string decode, against
        // the request's own (possibly child/OOPIF) session.
        await relay?.setBodyFetcher { [session] requestID, sessionId in
            await session.fetchResponseBodyData(requestID: requestID, sessionId: sessionId)
        }
        // On-demand segment fetch: run `fetch` inside the player's iframe session so the CDN's per-token
        // segment request is Service-Worker-signed exactly as the player's own is. This is how we obtain
        // segments we can never capture passively (they're served by a worker/SW we can't observe).
        await relay?.setSegmentFetcher { [session] url, sessionId in
            guard let parsed = safeURL(from: url) else { return (nil, "bad url") }
            return await session.fetchBinaryResourceInSession(at: parsed, sessionId: sessionId, timeout: 15)
        }

        let extractionTimeout = config.extractionTimeout
        do {
            let overallDeadline = Date().addingTimeInterval(extractionTimeout)
            return try await withTimeout(seconds: extractionTimeout) { [self] in
                try Task.checkCancellation()
                onProgress?("Navigating to target page...", 0.25)
                do {
                    ExtractionLogger.log("Navigating browser to \(sourcePageURL.absoluteString)...")
                    try await session.navigate(to: sourcePageURL, timeout: self.settings.browserTimeout)
                } catch {
                    if !(await collector.hasHits()) {
                        ExtractionLogger.log("Navigation error: \(error.localizedDescription)")
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
                    ExtractionLogger.log("No matching media stream requests captured.")
                    throw PolluxError.noStreamCaptured(sourcePageURL)
                }

                try Task.checkCancellation()
                ExtractionLogger.log("Captured \(entries.count) media candidate request(s). Fetching cookies and playlists...")

                let cookies = try await session.cookies()
                ExtractionLogger.log("Captured cookies: \(cookies.map { "\($0.name)=\($0.value) (\($0.domain))" })")
                let cachedPlaylists = await self.cachePlaylists(from: entries, session: session)
                let candidates = self.buildCandidates(
                    from: entries,
                    cachedPlaylists: cachedPlaylists,
                    cookies: cookies,
                    sourcePageURL: sourcePageURL,
                    userAgent: profile.userAgent
                )
                guard !candidates.isEmpty else {
                    ExtractionLogger.log("No valid candidates constructed from network entries.")
                    throw PolluxError.noStreamCaptured(sourcePageURL)
                }

                try Task.checkCancellation()
                if relay != nil {
                    onProgress?("Selecting player stream...", 0.85)
                    ExtractionLogger.log("Response-Relay Mode: selecting the player's master playlist (skipping ffprobe — the CDN blocks direct probes).")
                } else {
                    onProgress?("Validating candidate with ffprobe...", 0.85)
                    ExtractionLogger.log("Validating candidates with ffprobe...")
                }

                let selection = try await self.selectBestCandidate(from: candidates, session: session, cachedPlaylists: cachedPlaylists, relayMode: relay != nil)

                try Task.checkCancellation()
                onProgress?("Preparing playback...", 0.95)
                ExtractionLogger.log("SUCCESS: Selected stream (\(selection.kind)) at \(selection.candidate.url.absoluteString)")

                if let relay {
                    // Response-Relay Mode: keep the player alive and playing, and swap the noisy
                    // extraction handler for a quiet relay-only one that keeps mirroring the player's
                    // live media responses. The browser is intentionally NOT released here.
                    await relay.setStreamHost(selection.candidate.url.host)
                    await session.setEventHandler { method, params, sessionId in
                        await relay.handleEvent(method: method, paramsData: params, sessionId: sessionId)
                    }
                    // Nudge the player into actually playing so it keeps fetching the live window (which
                    // is what the relay serves). A viewport click via the Input domain reaches the
                    // cross-origin player iframe; JS play() on any top-frame <video> is a harmless extra.
                    try? await session.click(x: profile.centerX, y: profile.centerY)
                    await session.clickPlayButtons()
                    ExtractionLogger.log("Response-Relay Mode active: serving the player's captured media. Keeping the in-page player alive to feed the live window.")
                    // Keep-alive loop: a live stream only advances while the in-page player keeps playing
                    // and pulling new segments (which the relay mirrors). Every 3s, re-assert playback by
                    // resuming any paused <video> in the player's own session; log a lightweight relay
                    // heartbeat every ~30s. Exit cleanly once the browser is gone (the nudge fails).
                    Task.detached {
                        var idleFailures = 0
                        var tick = 0
                        while idleFailures < 5 {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if let playerSession = await relay.playerSession() {
                                let alive = await session.resumePausedVideos(inSession: playerSession)
                                idleFailures = alive ? 0 : idleFailures + 1
                            }
                            if tick % 10 == 0 {
                                let line = await relay.statsLine()
                                ExtractionLogger.log(line)
                            }
                            tick += 1
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
                        cookies: cookies,
                        session: session,
                        mediaRelay: relay
                    )
                }

                // Stop collecting/logging CDP events before playback begins. The session normally
                // stays alive for live playlist refresh, but the running player would otherwise flood
                // the logger and freeze the UI.
                await session.detachEventHandler()

                // Opt-in aggressive cleanup: tear the browser down immediately once a stream is
                // selected. Playback then refreshes live playlists over direct connections only.
                let releaseBrowser = config.releaseBrowserAfterExtraction
                if releaseBrowser {
                    await session.close()
                    ExtractionLogger.log("Released extraction browser after selection (per settings).")
                }

                return ExtractedStream(
                    sourcePageURL: sourcePageURL,
                    streamURL: selection.candidate.url,
                    headers: selection.candidate.headers,
                    kind: selection.kind,
                    cachedPlaylists: cachedPlaylists,
                    excludedVariantURLs: selection.excludedVariantURLs,
                    notice: selection.notice,
                    cookies: cookies,
                    session: releaseBrowser ? nil : session
                )
            }
        } catch is CancellationError {
            await session.close()
            ExtractionLogger.log("Stream extraction was cancelled.")
            throw CancellationError()
        } catch is TimeoutError {
            await session.close()
            ExtractionLogger.log("Extraction timed out after \(Int(extractionTimeout)) seconds.")
            throw PolluxError.extractionTimedOut(sourcePageURL, extractionTimeout)
        } catch {
            await session.close()
            ExtractionLogger.log("Extraction failed: \(error.localizedDescription)")
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
        ExtractionLogger.log("Starting player interaction pipeline...")

        // Autoplay grace: wait briefly for the stream to load on its own before any synthetic click.
        // Chromium runs with --autoplay-policy=no-user-gesture-required, so many players auto-load
        // their HLS. On sites that hijack the first click (popunder/redirect), clicking the content
        // page prematurely navigates it away and blanks the player before it ever appears — so an
        // early click actively prevents capture. Clicking still happens below if this grace lapses.
        let graceDeadline = Date().addingTimeInterval(min(settings.autoplayGrace, max(deadline.timeIntervalSinceNow - 1, 0)))
        if try await waitUntil(deadline: graceDeadline, interval: 0.3, { await collector.hasHits() }) {
            ExtractionLogger.log("Media candidate captured during autoplay grace period (no click needed).")
            return
        }

        // Some anti-bot pages serve a blank/broken document to headless automation on most loads and
        // only occasionally render the real player; the blank-page step re-navigates for another shot.
        // `pipelineStart` is stamped here (before any pass) so the iframe-navigation delay is measured
        // from the start of interaction, matching the pre-refactor behavior.
        var context = InteractionContext(
            session: session,
            profile: profile,
            deadline: deadline,
            sourcePageURL: sourcePageURL,
            settings: settings,
            pipelineStart: Date(),
            lastReload: Date()
        )

        // Driver: run the named steps in order, checking for a captured stream once between steps
        // instead of after each individual action. A step can ask to restart the pass (after a
        // blank-page reload) so the fresh document is re-inspected from the top.
        while Date() < deadline {
            try Task.checkCancellation()
            if await collector.hasHits() {
                ExtractionLogger.log("Media candidate captured: proceeding to validate.")
                return
            }

            context.jsMainThreadBlocked = false
            var restart = false
            for step in InteractionStep.pipeline {
                if await step.run(&context) == .restartLoop {
                    restart = true
                    break
                }
                if await collector.hasHits() {
                    ExtractionLogger.log(step.captureLog)
                    return
                }
            }
            if restart {
                continue
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
                    !isBrowserFetchError(fetched),
                    // Only cache real playlists. A CDN can 403 the browser fetch at extraction time and
                    // return an HTML error page (non-empty, not the "ERROR:" sentinel); caching that
                    // would later be served as bogus segments, spinning the player forever.
                    looksLikeHLSPlaylistText(fetched)
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
                StreamCandidate(url: url, headers: headers, kind: .hls, score: hlsCandidateScore(forURLString: url.absoluteString)),
                into: &deduped
            )
        }

        return deduped.values.sorted { lhs, rhs in
            isBetterCandidate(scoreL: lhs.score, urlL: lhs.url.absoluteString, scoreR: rhs.score, urlR: rhs.url.absoluteString)
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

    private func selectBestCandidate(
        from candidates: [StreamCandidate],
        session: ChromeBrowserSession,
        cachedPlaylists: [String: String],
        relayMode: Bool = false
    ) async throws -> CandidateSelection {
        // Response-Relay Mode serves the in-page player's own captured bytes, never the CDN directly.
        // ffprobe validates a candidate by fetching it directly — exactly what the CDN anti-leech 403s —
        // so probing here is both meaningless (we won't fetch that way) and a hang risk (a blocked probe
        // stalls until the watchdog fires). Skip it and take the master playlist the player is using.
        if relayMode {
            if let master = bestMasterPlaylistCandidate(from: candidates, cachedPlaylists: cachedPlaylists) {
                return CandidateSelection(candidate: master, kind: .hls, excludedVariantURLs: [], notice: nil)
            }
            let hls = candidates.filter { $0.kind == .hls }
            let pool = hls.isEmpty ? candidates : hls
            if let best = pool.sorted(by: { lhs, rhs in
                isBetterCandidate(scoreL: lhs.score, urlL: lhs.url.absoluteString, scoreR: rhs.score, urlR: rhs.url.absoluteString)
            }).first {
                return CandidateSelection(candidate: best, kind: best.kind, excludedVariantURLs: [], notice: nil)
            }
            throw PolluxError.noPlayableStream
        }

        let prober = try FFprobeService()

        // Probe only playable entry points — playlists and whole-file streams — not individual media
        // segments. A capture often yields many raw segment URLs (e.g. `.json`-disguised
        // MPEG-TS segments, which detect as HLS via their `video/mp2t` MIME); probing a single live
        // segment is pointless and its short-lived token blocks ffprobe until the watchdog fires.
        let probeCandidates = candidatesWorthProbing(candidates, cachedPlaylists: cachedPlaylists)

        let evaluations = await withTaskGroup(of: ProbeEvaluation.self, returning: [ProbeEvaluation].self) { group in
            for candidate in probeCandidates {
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
            isBetterCandidate(scoreL: lhs.score, urlL: lhs.url.absoluteString, scoreR: rhs.score, urlR: rhs.url.absoluteString)
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

/// Filters a candidate list to entry points worth probing: HLS playlists (by `.m3u8` extension or M3U8
/// body) and non-HLS whole-file streams. Bare HLS media segments — which detect as `.hls` only via their
/// `video/mp2t` MIME — are dropped, since a lone live segment isn't playable on its own and only burns a
/// probe on a short-lived token. Falls back to the full list if nothing qualifies, so a site that
/// exposes only segments isn't reduced to zero candidates.
func candidatesWorthProbing(
    _ candidates: [StreamCandidate],
    cachedPlaylists: [String: String]
) -> [StreamCandidate] {
    func isPlayableEntryPoint(_ candidate: StreamCandidate) -> Bool {
        guard candidate.kind == .hls else {
            return true
        }
        let ext = getPathAndExtension(from: candidate.url.absoluteString).pathExtension.lowercased()
        if ext == "m3u8" {
            return true
        }
        if let text = cachedPlaylists[candidate.url.absoluteString], text.uppercased().contains("#EXTM3U") {
            return true
        }
        return false
    }

    let entryPoints = candidates.filter(isPlayableEntryPoint)
    return entryPoints.isEmpty ? candidates : entryPoints
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
        .sorted { lhs, rhs in
            isBetterCandidate(scoreL: lhs.score, urlL: lhs.url.absoluteString, scoreR: rhs.score, urlR: rhs.url.absoluteString)
        }
        .first
}

/// Per-run settings resolved once from user defaults at the start of an extraction. Reading them all
/// in one place keeps the scattered `UserDefaults` lookups together and gives a single snapshot the
/// whole run shares.
struct ResolvedRunConfig {
    let verboseLogging: Bool
    let extractionTimeout: TimeInterval
    let releaseBrowserAfterExtraction: Bool
    let mediaRelay: Bool

    static func resolved(from defaults: UserDefaults = .standard) -> ResolvedRunConfig {
        ResolvedRunConfig(
            verboseLogging: defaults.bool(forKey: PolluxPreferences.verboseExtractionLoggingKey),
            extractionTimeout: CaptureRetryBudget.resolved(from: defaults),
            releaseBrowserAfterExtraction: defaults.bool(forKey: PolluxPreferences.releaseBrowserAfterExtractionKey),
            mediaRelay: defaults.bool(forKey: PolluxPreferences.mediaRelayKey)
        )
    }
}

struct ExtractionSettings {
    let browserTimeout: TimeInterval = 30
    let autoplayGrace: TimeInterval = 6
    let iframeNavigationDelay: TimeInterval = 14
    let blankPageReloadCooldown: TimeInterval = 6
    let graceAfterActions: TimeInterval = 15
    let collectionWindow: TimeInterval = 10
    let playlistFetchTimeout: TimeInterval = 6
    let maxCachedPlaylists = 12
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
