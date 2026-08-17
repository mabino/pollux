import Foundation

/// Captures the in-page player's own successful media responses (the live media playlist and its
/// segments) over CDP and caches their bytes, so the local proxy can serve them to AVPlayer without
/// re-fetching from the CDN. This is the core of Response-Relay Mode: it defeats CDN anti-leech that
/// rejects every request except the authorized player's, because we relay exactly the bytes the player
/// already downloaded rather than issuing our own (rejected) fetches.
///
/// The player must keep playing for the cache to stay fed (Response-Relay Mode forces a headful
/// browser and keeps it alive for the whole playback session).
actor MediaRelay {
    struct Entry: Sendable {
        let data: Data
        let contentType: String?
        let isPlaylist: Bool
        /// A media playlist (segment list, `#EXTINF`) as opposed to a master (`#EXT-X-STREAM-INF`).
        let isMediaPlaylist: Bool
        let sequence: Int
    }

    /// Only relay responses from the stream's CDN host (plus anything that looks like media by extension
    /// or MIME), so we don't pull unrelated page resources. Set once the selected stream's host is known.
    private var streamHost: String?
    private let maxSegments: Int
    private let maxTotalSegmentBytes: Int

    private var entries: [String: Entry] = [:]
    /// Absolute URLs referenced by captured playlists (segments, init segments, keys, sub-playlists).
    /// These are the exact URLs AVPlayer will request, so we relay them even when they live on a
    /// different host (e.g. a Cloudflare Worker) with no media extension.
    private var expectedMediaURLs: Set<String> = []
    /// Hosts that a captured playlist's segments live on (e.g. a Cloudflare Worker). Relayed wholesale,
    /// because a live segment URL is fetched exactly once and its `responseReceived` can arrive before
    /// the playlist body-fetch has populated `expectedMediaURLs` — matching by host closes that race so
    /// we don't miss the segment forever.
    private var mediaHosts: Set<String> = []
    /// Response metadata retained from `responseReceived` until the body is available at `loadingFinished`.
    /// `sessionId` is the flat-mode child-target (OOPIF) session the request belongs to, or nil for the
    /// top target — `getResponseBody` must be issued against that same session.
    private var pendingByRequestID: [String: (url: String, mimeType: String?, sessionId: String?)] = [:]
    private var capturedRequestIDs: Set<String> = []
    private var sequence = 0
    private var totalSegmentBytes = 0
    // Diagnostics (surfaced periodically in the Extraction Log during relay playback).
    private var storedPlaylistCount = 0
    private var storedSegmentCount = 0
    private var bodyFailureCount = 0
    private var servedCount = 0
    private var missedCount = 0
    private var lastStoredSegmentURL: String?
    private var lastMissedURL: String?
    /// The URL of the newest captured *media* playlist — the exact one the in-page player is using.
    /// Served for every AVPlayer playlist request so AVPlayer follows the player's variant instead of
    /// choosing its own from the master.
    private var currentMediaPlaylistURL: String?
    /// A growing, monotonic timeline assembled from every captured media playlist (deduped, in order).
    /// AVPlayer is served a synthetic playlist built from this — a stable window it can follow — instead
    /// of the player's raw live snapshot, whose sliding `EXT-X-MEDIA-SEQUENCE` jumps out from under a
    /// player that is legitimately a few segments behind live and makes it stall.
    private var orderedSegments: [(url: String, duration: Double)] = []
    private var segmentTimelineSet: Set<String> = []
    private var mediaSequenceBase: Int = 0
    private var targetDuration: Double = 6
    private var initSegmentURI: String?
    /// Nominal rewrite base for the synthetic playlist (segment URLs in it are absolute, so this only
    /// needs to be any valid URL). Set from the most recent media playlist we parsed.
    private var timelineBaseURL: URL?
    /// How many trailing segments to expose to AVPlayer. Kept well under `maxSegments` so every listed
    /// segment's bytes are still cached (or freshly re-fetchable) when requested.
    private let timelineWindow = 24
    /// Pulls a buffered response body (raw bytes + mime) by CDP request id and session id. Injected
    /// after the session exists.
    private var bodyFetcher: (@Sendable (String, String?) async -> (data: Data, mimeType: String?)?)?
    /// Fetches a URL by running `fetch` *inside* a given child-target session (the player iframe), so it
    /// travels through that origin's Service Worker and inherits its anti-leech signing. This is how we
    /// obtain the CDN's per-token segments that we can never fetch ourselves. Injected after the session
    /// exists.
    private var segmentFetcher: (@Sendable (String, String?) async -> (data: Data?, error: String?))?
    private var lastSegmentFetchError: String?
    /// The child-target session the player fetches its media in — where a re-fetch will be SW-signed.
    /// Learned from the session that delivered the media playlist.
    private var playerSessionId: String?
    /// Segment URLs currently being fetched through the browser, so concurrent AVPlayer requests for the
    /// same segment coalesce onto one in-flight fetch instead of racing.
    private var inFlightSegments: Set<String> = []
    private var segmentFetchCount = 0
    private var segmentFetchFailureCount = 0
    private var prefetchCount = 0

    init(streamHost: String?, maxSegments: Int = 60, maxTotalSegmentBytes: Int = 96 * 1024 * 1024) {
        self.streamHost = streamHost?.lowercased()
        self.maxSegments = maxSegments
        self.maxTotalSegmentBytes = maxTotalSegmentBytes
    }

    func setBodyFetcher(_ fetcher: @escaping @Sendable (String, String?) async -> (data: Data, mimeType: String?)?) {
        bodyFetcher = fetcher
    }

    func setSegmentFetcher(_ fetcher: @escaping @Sendable (String, String?) async -> (data: Data?, error: String?)) {
        segmentFetcher = fetcher
    }

    /// Narrows relaying to the selected stream's CDN host once it is known (after candidate selection),
    /// so disguised segments (media MIME but no media extension) under that host are captured too.
    func setStreamHost(_ host: String?) {
        streamHost = host?.lowercased()
    }

    /// Feed one CDP event. Mirrors `CaptureCollector`: the body pull runs on a detached task so the CDP
    /// receive loop (which awaits this handler inline) never blocks on a `getResponseBody` reply.
    func handleEvent(method: String, paramsData: Data, sessionId: String?) {
        guard let params = try? jsonDictionary(from: paramsData) else {
            return
        }
        switch method {
        case "Network.responseReceived":
            guard
                let requestID = params["requestId"] as? String,
                let response = params["response"] as? [String: Any],
                let url = response["url"] as? String
            else {
                return
            }
            let mimeType = response["mimeType"] as? String
            guard shouldRelay(url, mimeType: mimeType) else {
                return
            }
            let status = response["status"] as? Int ?? 0
            guard (200...299).contains(status) else {
                return
            }
            pendingByRequestID[requestID] = (url, mimeType, sessionId)

        case "Network.loadingFinished":
            guard
                let requestID = params["requestId"] as? String,
                let meta = pendingByRequestID.removeValue(forKey: requestID),
                bodyFetcher != nil,
                capturedRequestIDs.insert(requestID).inserted
            else {
                return
            }
            Task { await self.capture(requestID: requestID, url: meta.url, mimeType: meta.mimeType, sessionId: meta.sessionId) }

        default:
            break
        }
    }

    /// The exact cached bytes for a URL the player fetched, if present.
    func body(for url: String) -> Entry? {
        entries[url]
    }

    /// Bytes for a segment AVPlayer requested: the player's captured copy if we have it, otherwise a
    /// live `fetch` issued inside the player's iframe session (SW-signed) against the CDN. Caches the
    /// result. Returns nil if we can't obtain it (no player session yet, or the CDN rejected even the
    /// signed request), so the proxy can fall through to its normal path.
    func segmentData(for url: String) async -> Data? {
        if let entry = entries[url] {
            servedCount += 1
            return entry.data
        }
        guard let segmentFetcher, let playerSessionId else {
            recordMissed(url)
            return nil
        }
        // Coalesce concurrent requests for the same segment onto one browser fetch.
        if inFlightSegments.contains(url) {
            if let entry = await waitForBody(for: url, timeout: 6) {
                servedCount += 1
                return entry.data
            }
            recordMissed(url)
            return nil
        }
        inFlightSegments.insert(url)
        segmentFetchCount += 1
        let outcome = await segmentFetcher(url, playerSessionId)
        inFlightSegments.remove(url)
        if let data = outcome.data, !data.isEmpty {
            store(url: url, data: data, contentType: nil, isPlaylist: false, isMediaPlaylist: false)
            servedCount += 1
            return data
        }
        segmentFetchFailureCount += 1
        lastSegmentFetchError = outcome.error ?? "empty body"
        recordMissed(url)
        return nil
    }

    /// The newest captured media playlist (data + its own URL), to serve for AVPlayer playlist requests
    /// so it follows the in-page player's variant rather than picking its own from the master.
    func currentMediaPlaylist() -> (data: Data, contentType: String?, url: URL)? {
        guard let key = currentMediaPlaylistURL, let entry = entries[key], let url = URL(string: key) else {
            return nil
        }
        return (entry.data, entry.contentType, url)
    }

    /// A synthetic live media playlist built from the growing segment timeline — a stable window that
    /// only ever advances, so AVPlayer follows it continuously instead of stalling when the player's raw
    /// snapshot slides out from under it. Falls back to nil (proxy then serves `currentMediaPlaylist`)
    /// until enough of a timeline exists. The returned `url` is only a rewrite base; all segment URLs in
    /// the body are absolute, so the proxy rewrites them to itself regardless.
    func syntheticMediaPlaylist() -> (data: Data, contentType: String?, url: URL)? {
        guard orderedSegments.count >= 3,
              let base = timelineBaseURL ?? currentMediaPlaylistURL.flatMap({ URL(string: $0) }) else {
            return nil
        }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(targetDuration.rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequenceBase)",
        ]
        if let initSegmentURI {
            lines.append("#EXT-X-MAP:URI=\"\(initSegmentURI)\"")
        }
        for segment in orderedSegments {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append(segment.url)
        }
        let text = lines.joined(separator: "\n") + "\n"
        return (Data(text.utf8), "application/vnd.apple.mpegurl", base)
    }

    /// Parse a captured *media* playlist and append any new segments (with durations) to the growing
    /// timeline, trimming the front to `timelineWindow` and advancing the media-sequence base so the
    /// exposed playlist stays a bounded, monotonic window.
    /// Internal (not private) so the timeline/synthetic-playlist logic can be unit-tested directly by
    /// feeding captured media-playlist bytes without standing up a live CDP session.
    func recordMediaTimeline(fromMediaPlaylist data: Data, playlistURL: URL) {
        timelineBaseURL = playlistURL
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var pendingDuration: Double?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                if let value = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) {
                    targetDuration = max(targetDuration, value)
                }
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uriRange = line.range(of: "URI=\""),
                   let closing = line[uriRange.upperBound...].firstIndex(of: "\"") {
                    let uri = String(line[uriRange.upperBound..<closing])
                    if let absolute = safeURL(from: uri, relativeTo: playlistURL)?.absoluteURL {
                        initSegmentURI = absolute.absoluteString
                    }
                }
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                let digits = line.dropFirst("#EXTINF:".count).prefix { $0 == "." || $0.isNumber }
                pendingDuration = Double(digits)
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let absolute = safeURL(from: line, relativeTo: playlistURL)?.absoluteURL else {
                pendingDuration = nil
                continue
            }
            let key = absolute.absoluteString
            if !segmentTimelineSet.contains(key) {
                segmentTimelineSet.insert(key)
                orderedSegments.append((key, pendingDuration ?? targetDuration))
                // Prefetch the moment a segment appears — before AVPlayer reaches it — so its request is
                // an instant cache hit and it can build a buffer ahead of the live edge instead of
                // stalling on each on-demand fetch's round-trip latency.
                Task { await self.prefetchSegment(key) }
            }
            pendingDuration = nil
        }
        if orderedSegments.count > timelineWindow {
            let drop = orderedSegments.count - timelineWindow
            for removed in orderedSegments.prefix(drop) {
                segmentTimelineSet.remove(removed.url)
            }
            orderedSegments.removeFirst(drop)
            mediaSequenceBase += drop
        }
    }

    /// The child-target session the in-page player runs in, for periodic keep-alive playback nudges.
    func playerSession() -> String? { playerSessionId }

    /// Fetch a segment ahead of demand and cache it, without touching served/missed accounting (that's
    /// for AVPlayer's own requests). Coalesces with any in-flight fetch for the same URL.
    private func prefetchSegment(_ url: String) async {
        guard entries[url] == nil,
              !inFlightSegments.contains(url),
              let segmentFetcher,
              let playerSessionId else {
            return
        }
        inFlightSegments.insert(url)
        prefetchCount += 1
        let outcome = await segmentFetcher(url, playerSessionId)
        inFlightSegments.remove(url)
        if let data = outcome.data, !data.isEmpty {
            store(url: url, data: data, contentType: nil, isPlaylist: false, isMediaPlaylist: false)
        }
    }

    func recordServed() { servedCount += 1 }
    func recordMissed(_ url: String) {
        missedCount += 1
        lastMissedURL = url
    }

    /// A one-line snapshot of relay activity for the Extraction Log. On a miss it also shows the last
    /// missed vs last stored segment URL, which reveals a URL-normalization or variant mismatch.
    func statsLine() -> String {
        var line = "Relay: cached \(storedPlaylistCount) playlists / \(storedSegmentCount) segments (\(entries.count) live) · expected \(expectedMediaURLs.count) · media-pl \(currentMediaPlaylistURL != nil ? "yes" : "no") · seg-fetch \(segmentFetchCount) (fail \(segmentFetchFailureCount)) · served \(servedCount) · missed \(missedCount)"
        line += " · prefetch \(prefetchCount) · timeline \(orderedSegments.count)@seq\(mediaSequenceBase) · player-session \(playerSessionId != nil ? "yes" : "no")"
        if let err = lastSegmentFetchError {
            line += "\n  last seg-err: \(err)"
        }
        if missedCount > 0, let missed = lastMissedURL {
            line += "\n  last miss:   \(missed)"
            line += "\n  last stored: \(lastStoredSegmentURL ?? "(none)")"
        }
        return line
    }

    /// Waits up to `timeout` for the player to fetch `url` (it downloads the live window a little ahead
    /// of us), returning the cached bytes or nil if they never arrive.
    func waitForBody(for url: String, timeout: TimeInterval) async -> Entry? {
        if let entry = entries[url] {
            return entry
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let entry = entries[url] {
                return entry
            }
        }
        return entries[url]
    }

    private func shouldRelay(_ url: String, mimeType: String?) -> Bool {
        // The exact URLs a captured playlist references (segments/keys/sub-playlists) — the most
        // reliable signal, and the only one that catches segments served from an unrelated host with no
        // media extension (e.g. a Cloudflare Worker at `.../p/<token>`).
        if expectedMediaURLs.contains(url) {
            return true
        }
        let host = URL(string: url)?.host?.lowercased()
        // Any host a captured playlist points its segments at (covers off-host, extension-less worker
        // segments whose per-URL token means we only ever see each one once).
        if let host, mediaHosts.contains(host) {
            return true
        }
        // Everything from the selected stream's CDN host (covers disguised segments with no media
        // extension), plus anything that looks like media by extension or MIME on other hosts.
        if let streamHost, let host, host == streamHost {
            return true
        }
        let ext = getPathAndExtension(from: url).pathExtension.lowercased()
        if ["m3u8", "ts", "m4s", "mp4", "m4a", "aac", "mp3", "key"].contains(ext) {
            return true
        }
        if let mimeType, StreamKind.fromMIME(mimeType) != nil {
            return true
        }
        return false
    }

    /// Parse a captured playlist and remember every URL it references, so those responses are relayed
    /// the moment the player fetches them — even off-host, extension-less segments.
    private func recordExpectedMedia(fromPlaylist data: Data, playlistURL: URL?) {
        guard let playlistURL else { return }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                // Attribute URIs on tags like #EXT-X-MAP / #EXT-X-KEY.
                if let uriRange = line.range(of: "URI=\""),
                   let closing = line[uriRange.upperBound...].firstIndex(of: "\"") {
                    let uri = String(line[uriRange.upperBound..<closing])
                    if let absolute = safeURL(from: uri, relativeTo: playlistURL)?.absoluteURL {
                        expectedMediaURLs.insert(absolute.absoluteString)
                        if let host = absolute.host?.lowercased() { mediaHosts.insert(host) }
                    }
                }
                continue
            }
            if let absolute = safeURL(from: line, relativeTo: playlistURL)?.absoluteURL {
                expectedMediaURLs.insert(absolute.absoluteString)
                if let host = absolute.host?.lowercased() { mediaHosts.insert(host) }
            }
        }
    }

    private func capture(requestID: String, url: String, mimeType: String?, sessionId: String?) async {
        guard let bodyFetcher else { return }
        guard let fetched = await bodyFetcher(requestID, sessionId), !fetched.data.isEmpty else {
            bodyFailureCount += 1
            return
        }
        let ext = getPathAndExtension(from: url).pathExtension.lowercased()
        let text = String(decoding: fetched.data, as: UTF8.self)
        let isPlaylist = ext == "m3u8" || looksLikeHLSPlaylistText(String(text.prefix(16)))
        let isMediaPlaylist = isPlaylist && !isMasterHLSPlaylist(text)
        // Remember the session that carries the player's media playlist — a `fetch` issued there for a
        // segment inherits the player's Service-Worker signing, which is how we obtain CDN segments.
        if isMediaPlaylist {
            playerSessionId = sessionId
        }
        store(url: url, data: fetched.data, contentType: mimeType ?? fetched.mimeType, isPlaylist: isPlaylist, isMediaPlaylist: isMediaPlaylist)
    }

    private func store(url: String, data: Data, contentType: String?, isPlaylist: Bool, isMediaPlaylist: Bool) {
        sequence += 1
        if let existing = entries[url], !existing.isPlaylist {
            totalSegmentBytes -= existing.data.count
        }
        entries[url] = Entry(data: data, contentType: contentType, isPlaylist: isPlaylist, isMediaPlaylist: isMediaPlaylist, sequence: sequence)
        if isPlaylist {
            storedPlaylistCount += 1
            recordExpectedMedia(fromPlaylist: data, playlistURL: URL(string: url))
            if isMediaPlaylist {
                currentMediaPlaylistURL = url
                if let playlistURL = URL(string: url) {
                    recordMediaTimeline(fromMediaPlaylist: data, playlistURL: playlistURL)
                }
            }
        } else {
            storedSegmentCount += 1
            totalSegmentBytes += data.count
            lastStoredSegmentURL = url
        }
        evictIfNeeded()
    }

    /// Evict the oldest *segments* (never playlists) until back within the count and byte limits.
    private func evictIfNeeded() {
        guard totalSegmentBytes > maxTotalSegmentBytes || segmentCount > maxSegments else {
            return
        }
        var segments = entries
            .filter { !$0.value.isPlaylist }
            .sorted { $0.value.sequence < $1.value.sequence }
        while (segments.count > maxSegments || totalSegmentBytes > maxTotalSegmentBytes),
              let oldest = segments.first {
            entries.removeValue(forKey: oldest.key)
            totalSegmentBytes -= oldest.value.data.count
            segments.removeFirst()
        }
    }

    private var segmentCount: Int {
        entries.values.reduce(0) { $0 + ($1.isPlaylist ? 0 : 1) }
    }
}
