import Foundation

actor CaptureCollector {
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

    /// Response metadata retained from `Network.responseReceived` so a body fetch on
    /// `Network.loadingFinished` (when the body is actually available) knows what it is looking at.
    private var responseURLByID: [String: String] = [:]
    /// Fetches a buffered response body by CDP request id. Injected after the browser session launches
    /// (the collector is created first, to be the session's event handler). Nil until then.
    private var bodyFetcher: (@Sendable (String) async -> String?)?
    private var scannedRequestIDs: Set<String> = []
    /// Upper bound on API bodies we will pull and scan, so a chatty page can't make us fetch hundreds.
    private let maxResponseBodyScans = 40

    init(patterns: [String], maxCandidates: Int) {
        self.patterns = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        self.maxCandidates = maxCandidates
    }

    func setBodyFetcher(_ fetcher: @escaping @Sendable (String) async -> String?) {
        bodyFetcher = fetcher
    }

    /// Single entry point for every CDP event, dispatching to the named capture strategy for that
    /// event. Each strategy is independent and additive — a site's stream may surface through any of
    /// them (a plain media request, a response MIME, a stream URL buried in an API body, or a console
    /// log line), so all run for every page.
    func handleEvent(method: String, paramsData: Data) {
        guard let params = try? jsonDictionary(from: paramsData) else {
            return
        }

        switch method {
        case "Network.requestWillBeSent":  captureRequest(params)      // passive sniff (request side)
        case "Network.responseReceived":   captureResponse(params)     // passive sniff (response side)
        case "Network.loadingFinished":    scheduleBodyScan(params)    // API/XHR response-body scan
        case "Runtime.consoleAPICalled":   captureConsoleURLs(params)  // console log sniff
        default:                           return
        }
    }

    /// Passive sniff, request side: register any request whose URL matches a media pattern, and stash
    /// its headers so a later `responseReceived` for the same request id can reuse them.
    private func captureRequest(_ params: [String: Any]) {
        let requestID = params["requestId"] as? String
        let request = params["request"] as? [String: Any]
        let url = request?["url"] as? String
        let headers = headerMap(from: request?["headers"])
        if let requestID {
            requestHeadersByID[requestID] = headers
        }
        if let url {
            add(url: url, headers: headers, mimeType: nil, requirePatternMatch: true)
        }
    }

    /// Passive sniff, response side: register any response whose MIME type is a known stream kind, and
    /// mark stream-config-looking API responses so their body can be scanned once buffered.
    private func captureResponse(_ params: [String: Any]) {
        let requestID = params["requestId"] as? String
        let response = params["response"] as? [String: Any]
        let url = response?["url"] as? String
        let mimeType = response?["mimeType"] as? String
        let headers = requestID.flatMap { requestHeadersByID[$0] } ?? headerMap(from: response?["requestHeaders"])
        if let url {
            add(url: url, headers: headers, mimeType: mimeType, requirePatternMatch: false)
            // Remember JSON/text API responses that look like they carry stream config, so the
            // loadingFinished handler can pull the body once it is buffered.
            if let requestID, shouldScanResponseBody(url: url, mimeType: mimeType) {
                responseURLByID[requestID] = url
            }
        }
    }

    /// API/XHR body-scan strategy: once a marked response has finished loading (body now buffered),
    /// pull and scan it for embedded stream URLs.
    private func scheduleBodyScan(_ params: [String: Any]) {
        guard
            let requestID = params["requestId"] as? String,
            let url = responseURLByID.removeValue(forKey: requestID),
            bodyFetcher != nil,
            scannedRequestIDs.count < maxResponseBodyScans,
            scannedRequestIDs.insert(requestID).inserted
        else {
            return
        }
        // Fetch + scan on a detached task: the event handler is awaited inline by the CDP receive
        // loop, so awaiting a getResponseBody CDP call here would deadlock (its reply is delivered
        // by that same loop). Detaching lets the loop keep draining while we wait for the body.
        Task { await self.scanResponseBody(requestID: requestID, url: url) }
    }

    /// Console-sniff strategy: harvest any `.m3u8` URL a player logs to the console (only reachable
    /// when `Runtime.enable` is on, i.e. mitigation off).
    private func captureConsoleURLs(_ params: [String: Any]) {
        let args = params["args"] as? [[String: Any]] ?? []
        for argument in args {
            let rawValue = argument["value"] as? String ?? argument["description"] as? String ?? ""
            for capturedURL in m3u8Regex.matches(in: rawValue) {
                add(url: capturedURL, headers: [:], mimeType: nil, requirePatternMatch: true)
            }
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
                isBetterCandidate(scoreL: lhs.score, urlL: lhs.rawURL, scoreR: rhs.score, urlR: rhs.rawURL)
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
            existing.score = max(existing.score, hlsCandidateScore(forURLString: url))
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
            score: hlsCandidateScore(forURLString: url)
        )
        ExtractionLogger.log("CAPTURED MEDIA CANDIDATE: \(url)")
    }

    /// Whether an API/XHR response is worth pulling and scanning for embedded stream URLs. Restricted to
    /// textual/JSON responses whose URL hints at a stream-config endpoint, to keep body fetches targeted.
    private func shouldScanResponseBody(url: String, mimeType: String?) -> Bool {
        let mime = mimeType?.lowercased() ?? ""
        let isTextual = mime.isEmpty || mime.contains("json") || mime.contains("javascript") || mime.contains("text")
        guard isTextual else {
            return false
        }
        let lowered = url.lowercased()
        let hints = [
            "stream=true", "match/detail", "getstream", "get_stream", "playurl", "play_url",
            "/stream", "/source", "/channel", "/live", "/play", "m3u8", "/hls",
        ]
        return hints.contains { lowered.contains($0) }
    }

    /// Pulls a buffered API response body and harvests any HLS stream URLs it contains, registering them
    /// as capture candidates. This is the path that recovers the stream when an anti-bot player is handed
    /// its config over the network (JSON) but never issues the `.m3u8` request itself.
    private func scanResponseBody(requestID: String, url: String) async {
        guard let bodyFetcher, let body = await bodyFetcher(requestID), !body.isEmpty else {
            return
        }
        // JSON escapes forward slashes as `\/`; normalize so URLs are matchable.
        let normalized = body.replacingOccurrences(of: "\\/", with: "/")
        var discovered = Set<String>()
        for candidate in m3u8Regex.matches(in: normalized) {
            discovered.insert(candidate)
        }
        for candidate in hlsURLRegex.matches(in: normalized) {
            discovered.insert(candidate)
        }
        guard !discovered.isEmpty else {
            return
        }
        for streamURL in discovered {
            // Synthesize an HLS mime so the candidate survives `add`'s non-pattern gate and is later
            // classified as HLS even when the URL carries no `.m3u8` suffix.
            add(url: streamURL, headers: [:], mimeType: StreamKind.hls.mimeType, requirePatternMatch: false)
            ExtractionLogger.log("Recovered stream URL from API response \(url): \(streamURL)")
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

}

