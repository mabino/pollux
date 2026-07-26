import XCTest
@testable import Pollux

final class PolluxTests: XCTestCase {
    func testParsePageURLRequiresHTTPOrHTTPS() throws {
        let parsed = try parsePageURL("https://example.com/watch/123")
        XCTAssertEqual(parsed.host, "example.com")

        XCTAssertThrowsError(try parsePageURL("example.com/watch/123"))
        XCTAssertThrowsError(try parsePageURL("ftp://example.com/video"))
    }

    func testStreamKindPrefersExtensionOverMimeType() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/master.m3u8?token=abc"))
        XCTAssertEqual(StreamKind.detect(url: url, mimeType: "video/mp4"), .hls)
    }

    func testPlaylistRewriterRewritesSegmentsAndKeyURIs() throws {
        let playlistURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/master.m3u8"))
        let variantURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/video/index.m3u8"))
        let keyURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/keys/key.bin"))

        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"
        video/index.m3u8
        """

        let rewrittenData = try rewritePlaylistData(Data(playlist.utf8), playlistURL: playlistURL) {
            ProxyURLBuilder.proxyURL(port: 7777, targetURL: $0)
        }
        let rewritten = String(decoding: rewrittenData, as: UTF8.self)

        XCTAssertTrue(rewritten.contains(ProxyURLBuilder.proxyURL(port: 7777, targetURL: variantURL).absoluteString))
        XCTAssertTrue(rewritten.contains(ProxyURLBuilder.proxyURL(port: 7777, targetURL: keyURL).absoluteString))
    }

    func testCachedPlaylistHeuristicMatchesMastersAndCompletedVOD() {
        XCTAssertTrue(shouldServeCachedPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=12345\nvariant.m3u8"))
        XCTAssertTrue(shouldServeCachedPlaylist("#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST"))
        XCTAssertFalse(shouldServeCachedPlaylist("#EXTM3U\n#EXTINF:6,\nsegment.ts"))
        XCTAssertTrue(isMasterHLSPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=12345\nvariant.m3u8"))
        XCTAssertFalse(isMasterHLSPlaylist("#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST"))
    }

    func testReferencedHLSPlaylistURLsFindsRelativeAndAttributePlaylists() throws {
        let playlistURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/master.m3u8"))
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio/track.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=12345
        video/main.m3u8
        segment.ts
        """

        let referenced = referencedHLSPlaylistURLs(in: playlist, playlistURL: playlistURL)
        XCTAssertEqual(
            Set(referenced.map { $0.absoluteString }),
            Set([
                "https://cdn.example.com/root/audio/track.m3u8",
                "https://cdn.example.com/root/video/main.m3u8",
            ])
        )
    }

    func testFilterExcludedVariantsFromMasterPlaylistRemovesRejectedVariant() throws {
        let playlistURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/master.m3u8"))
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000
        high/mono.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=700000
        low/mono.m3u8
        """

        let filtered = filterExcludedVariantsFromMasterPlaylist(
            Data(playlist.utf8),
            playlistURL: playlistURL,
            excludedVariantURLs: ["https://cdn.example.com/root/high/mono.m3u8"]
        )
        let filteredText = String(decoding: filtered, as: UTF8.self)

        XCTAssertFalse(filteredText.contains("high/mono.m3u8"))
        XCTAssertTrue(filteredText.contains("low/mono.m3u8"))
    }

    func testPreferredPlaybackCandidatesPrefersMasterWhenAvailable() throws {
        let masterURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/playlist.m3u8"))
        let variantURL = try XCTUnwrap(URL(string: "https://cdn.example.com/root/low/mono.m3u8"))

        let master = StreamCandidate(url: masterURL, headers: [:], kind: .hls, score: 50)
        let variant = StreamCandidate(url: variantURL, headers: [:], kind: .hls, score: 0)
        let preferred = preferredPlaybackCandidates(
            from: [master, variant],
            cachedPlaylists: [
                masterURL.absoluteString: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=12345\nlow/mono.m3u8",
                variantURL.absoluteString: "#EXTM3U\n#EXTINF:6,\nsegment.ts",
            ]
        )

        XCTAssertEqual(preferred.map { $0.url.absoluteString }, [masterURL.absoluteString])
    }

    func testPNGHeaderStripperLeavesNormalDataAndRemovesLeadingImage() {
        let payload = Data("video-segment".utf8)
        XCTAssertEqual(stripPNGHeaderIfNeeded(payload), payload)

        let pngHeader = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
        let wrapped = pngHeader + Data(repeating: 0x00, count: 8) + iend + payload
        XCTAssertEqual(stripPNGHeaderIfNeeded(wrapped), payload)
    }

    func testDecodeBase64DataURL() {
        let raw = "data:video/mp2t;base64,SGVsbG8="
        XCTAssertEqual(decodeBase64DataURL(raw), Data("Hello".utf8))
        XCTAssertNil(decodeBase64DataURL("not-a-data-url"))
    }

    func testLocateExecutableUsesStoredPreferenceOverride() throws {
        let suiteName = "PolluxTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = directory.appendingPathComponent("ffprobe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        defaults.set(executableURL.path, forKey: PolluxPreferences.ffprobePathKey)

        let resolved = locateExecutable(
            envName: "POLLUX_FFPROBE_PATH",
            defaultsKey: PolluxPreferences.ffprobePathKey,
            fallbackNames: ["ffprobe"],
            userDefaults: defaults,
            environment: ["PATH": ""]
        )

        XCTAssertEqual(resolved?.path, executableURL.path)
    }

    func testPermissionSupportMetadata() {
        XCTAssertEqual(PolluxPermissionIssue.appManagement.systemSettingsLabel, "App Management")
        XCTAssertTrue(PolluxPermissionIssue.appManagement.systemSettingsURL.absoluteString.contains("Privacy_AppManagement"))
        XCTAssertEqual(
            permissionResetArguments(for: .appManagement, bundleIdentifier: "io.github.mabino.pollux"),
            ["reset", "AppManagement", "io.github.mabino.pollux"]
        )
    }

    func testAcceptsHLSProbeResultWithPotentialVideoAndAudio() {
        let result = ProbeResult(
            kind: .hls,
            bitRate: 0,
            hasVideo: false,
            hasAudio: true,
            hasPotentialVideo: true
        )

        XCTAssertTrue(acceptsProbeResult(result, for: .hls))
        XCTAssertNotNil(probeResultNotice(result, for: .hls))
    }

    func testRejectsImageOnlyHLSProbeResult() {
        let result = ProbeResult(
            kind: .hls,
            bitRate: 0,
            hasVideo: false,
            hasAudio: false,
            hasPotentialVideo: false
        )

        XCTAssertFalse(acceptsProbeResult(result, for: .hls))
        XCTAssertNil(probeResultNotice(result, for: .hls))
    }

    func testCanonicalizedHeadersStripsHostHeader() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/watch"))
        let captured = [
            "Host": "example.com",
            "User-Agent": "TestUA",
            ":method": "GET"
        ]
        let cleaned = canonicalizedHeaders(captured, sourcePageURL: sourceURL, userAgent: "TestUA")
        XCTAssertNil(cleaned["Host"])
        XCTAssertNil(cleaned["host"])
        XCTAssertEqual(cleaned["User-Agent"], "TestUA")
    }

    func testInvestigateMLB() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://jack23eo.mpcourageny9i9zzipper.my/baseball/major-league-baseball-2196986/cleveland-guardians-vs-minnesota-twins.html?icg=VVM&ilang=en"))
        XCTAssertEqual(pageURL.scheme, "https")
    }

    func testInvestigatePageURL() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/watch/stream-1/admin/1"))
        XCTAssertEqual(pageURL.scheme, "https")
    }

    func testSafeURLAndPathExtensionParsing() throws {
        // A token URL containing characters that require percent encoding
        let rawURL = "https://lb11.cdn-stream.example/secure/IKXwxNXuoIEAAhWbXuuPbTsXJiuZAfbJ/rtmp/stream/lNAs5o6_rC8cGmMqGKoVKBb_pfc5xlP1Dlaz3OlrQfP9dXQ3PLsnvhV2UlbGSIWZLzUmfLfVmOZu-gR90fUokw/1/playlist.m3u8?token=abc 123"
        
        // 1. Verify safeURL(from:) successfully creates a valid URL and normalizes spaces
        let url = try XCTUnwrap(safeURL(from: rawURL))
        XCTAssertEqual(url.host, "lb11.cdn-stream.example")
        XCTAssertTrue(url.absoluteString.contains("token=abc%20123"))
        
        // 2. Verify getPathAndExtension(from:) correctly parses the path and extension
        let parsed = getPathAndExtension(from: rawURL)
        XCTAssertEqual(parsed.path, "/secure/IKXwxNXuoIEAAhWbXuuPbTsXJiuZAfbJ/rtmp/stream/lNAs5o6_rC8cGmMqGKoVKBb_pfc5xlP1Dlaz3OlrQfP9dXQ3PLsnvhV2UlbGSIWZLzUmfLfVmOZu-gR90fUokw/1/playlist.m3u8")
        XCTAssertEqual(parsed.pathExtension, "m3u8")
    }

    func testSafeRelativeURLResolution() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://lb11.cdn-stream.example/secure/rtmp/stream/1/playlist.m3u8"))
        
        // A relative path containing unescaped spaces
        let relativePath = "high/mono.m3u8?token=abc 123"
        let resolved = try XCTUnwrap(safeURL(from: relativePath, relativeTo: baseURL))
        
        XCTAssertEqual(resolved.absoluteString, "https://lb11.cdn-stream.example/secure/rtmp/stream/1/high/mono.m3u8?token=abc%20123")
    }

    func testIsPlaylistClassification() throws {
        let hlsURL = try XCTUnwrap(URL(string: "https://example.com/stream.m3u8"))
        let tsURL = try XCTUnwrap(URL(string: "https://example.com/segment.ts"))
        let mp4URL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        XCTAssertTrue(hlsURL.pathExtension.lowercased() == "m3u8")
        XCTAssertFalse(tsURL.pathExtension.lowercased() == "m3u8")
        XCTAssertFalse(mp4URL.pathExtension.lowercased() == "m3u8")

        let hlsContentType = "application/x-mpegURL"
        XCTAssertTrue(hlsContentType.lowercased().contains("mpegurl"))
    }

    func testProxyURLBuilderMapsImageExtensionsToTS() throws {
        let targetURL = try XCTUnwrap(URL(string: "https://p16-common-sign.tiktokcdn.com/segment.image?token=123"))
        let proxyURL = ProxyURLBuilder.proxyURL(port: 5555, targetURL: targetURL)

        XCTAssertEqual(proxyURL.pathExtension, "ts")
        XCTAssertEqual(proxyURL.path, "/proxy/stream.ts")
    }

    @MainActor
    func testRecentStreamsStoreDeduplicatesCapsAndClears() {
        let suiteName = "PolluxTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentStreamsStore(userDefaults: defaults)

        store.add("https://a.example/1")
        store.add("https://b.example/2")
        store.add("https://a.example/1") // duplicate -> moves to front, no growth
        XCTAssertEqual(store.urls, ["https://a.example/1", "https://b.example/2"])

        // Case-insensitive de-duplication.
        store.add("HTTPS://A.EXAMPLE/1")
        XCTAssertEqual(store.urls.count, 2)
        XCTAssertEqual(store.urls.first, "HTTPS://A.EXAMPLE/1")

        // Blank input is ignored.
        store.add("   ")
        XCTAssertEqual(store.urls.count, 2)

        // Cap at 10 most-recent.
        for index in 0..<15 {
            store.add("https://example.com/\(index)")
        }
        XCTAssertEqual(store.urls.count, 10)
        XCTAssertEqual(store.urls.first, "https://example.com/14")

        // Persistence: a new store reads the same backing defaults.
        let reloaded = RecentStreamsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.urls, store.urls)

        store.clear()
        XCTAssertTrue(store.urls.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: PolluxPreferences.recentStreamsKey))
    }

    func testCaptureRetryBudgetDefaultsWhenUnset() {
        let suiteName = "PolluxTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(CaptureRetryBudget.resolved(from: defaults), CaptureRetryBudget.defaultSeconds)
    }

    func testCaptureRetryBudgetClampsStoredValue() {
        let suiteName = "PolluxTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(5.0, forKey: PolluxPreferences.captureRetryBudgetKey)
        XCTAssertEqual(CaptureRetryBudget.resolved(from: defaults), CaptureRetryBudget.minSeconds)

        defaults.set(9999.0, forKey: PolluxPreferences.captureRetryBudgetKey)
        XCTAssertEqual(CaptureRetryBudget.resolved(from: defaults), CaptureRetryBudget.maxSeconds)

        defaults.set(120.0, forKey: PolluxPreferences.captureRetryBudgetKey)
        XCTAssertEqual(CaptureRetryBudget.resolved(from: defaults), 120)
    }

    func testProxyURLBuilderNormalizesObfuscatedSegmentExtensionsToTS() {
        // Segments disguised as .json / .php / no extension are MPEG-TS in practice. A player's HLS
        // demuxer rejects unknown segment extensions ("not in allowed_segment_extensions"), so the
        // proxy must present them as .ts. Regression guard for the disguised-.json streams.
        for raw in [
            "https://cdn.example.com/super/ts77.one_3x_753500-1784670268423.json?_ver=1784670274&_s1=a09ece45",
            "https://cdn.example.com/seg/12345.php?token=abc",
            "https://cdn.example.com/seg/chunk-0001?token=abc",
            "https://cdn.example.com/seg/frame.png",
        ] {
            XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: raw), ".ts", "should normalize \(raw) to .ts")
        }
    }

    func testProxyURLBuilderPreservesRealMediaAndControlExtensions() {
        // Genuine container / control extensions must survive so the demuxer handles them correctly.
        XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: "https://cdn.example.com/seg/0001.ts"), ".ts")
        XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: "https://cdn.example.com/seg/0001.m4s?x=1"), ".m4s")
        XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: "https://cdn.example.com/seg/0001.mp4"), ".mp4")
        XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: "https://cdn.example.com/audio/a.aac"), ".aac")
        XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: "https://cdn.example.com/v/index.m3u8?t=1"), ".m3u8")
        XCTAssertEqual(ProxyURLBuilder.proxyExtension(for: "https://cdn.example.com/keys/key.key"), ".key")
    }

    // MARK: - Live playback regression guards

    func testManifestResponseHeadersAlwaysMarkPlaylistNonCacheable() {
        let headers = hlsManifestResponseHeaders(contentLength: 42)

        // A live media playlist MUST be re-requested on every reload; if the player is allowed to
        // cache it, playback freezes once the first window is consumed (the ~16s stall).
        XCTAssertEqual(headers["Cache-Control"], "no-cache, no-store, must-revalidate")
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["Content-Type"], StreamKind.hls.mimeType)
        XCTAssertEqual(headers["Content-Length"], "42")
    }

    func testManifestResponseHeadersOverrideCacheableBaseHeaders() {
        // Even when the upstream response advertised itself as cacheable, the proxy must strip that.
        let base = [
            "Cache-Control": "public, max-age=3600",
            "Age": "120",
        ]
        let headers = hlsManifestResponseHeaders(contentLength: 7, baseHeaders: base)

        XCTAssertEqual(headers["Cache-Control"], "no-cache, no-store, must-revalidate")
        XCTAssertEqual(headers["Age"], "120")
    }

    func testUpstreamPlaylistFailureFallsBackToCachedCopy() {
        // A 403 (or any non-2xx / empty body) on a live playlist refresh must degrade to the cached
        // copy, never surface to the player as a broken "playlist". Guards the 403 regression.
        XCTAssertTrue(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: true, upstreamStatus: 403, bodyIsEmpty: false, hasCachedCopy: true))
        XCTAssertTrue(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: true, upstreamStatus: 200, bodyIsEmpty: true, hasCachedCopy: true))
        XCTAssertTrue(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: true, upstreamStatus: 0, bodyIsEmpty: true, hasCachedCopy: true))
    }

    func testUpstreamPlaylistSuccessDoesNotFallBackToCachedCopy() {
        // A healthy fresh playlist must win over the stale cache, otherwise the live window never
        // advances.
        XCTAssertFalse(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: true, upstreamStatus: 200, bodyIsEmpty: false, hasCachedCopy: true))
        XCTAssertFalse(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: true, upstreamStatus: 206, bodyIsEmpty: false, hasCachedCopy: true))
        // Segments are not playlists, and there is nothing to fall back to without a cached copy.
        XCTAssertFalse(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: false, upstreamStatus: 403, bodyIsEmpty: false, hasCachedCopy: true))
        XCTAssertFalse(shouldServeCachedManifestOnUpstreamFailure(
            isPlaylist: true, upstreamStatus: 403, bodyIsEmpty: false, hasCachedCopy: false))
    }

    func testValidationProxyDoesNotCloseBorrowedSession() async throws {
        // The ffprobe validation proxy borrows the shared Chrome session. If it closes that session
        // on stop, live playlist refresh during playback dies and the feed freezes/403s. Root-cause
        // guard for the regression.
        let spy = SpyBrowserSession()
        let proxy = try StreamProxyServer(stream: makeStream(session: spy), ownsSession: false)

        await proxy.stop()
        // Give any (erroneous) detached close task time to run before asserting it did not.
        try await Task.sleep(nanoseconds: 300_000_000)

        let closeCount = await spy.closeCount
        XCTAssertEqual(closeCount, 0, "A borrowed session must survive proxy teardown for live refresh.")
    }

    func testPlaybackProxyClosesOwnedSession() async throws {
        // The playback proxy owns the session and must tear Chrome down when playback ends.
        let spy = SpyBrowserSession()
        let proxy = try StreamProxyServer(stream: makeStream(session: spy), ownsSession: true)

        await proxy.stop()

        var closeCount = 0
        for _ in 0..<100 {
            closeCount = await spy.closeCount
            if closeCount > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(closeCount, 1, "An owned session must be closed exactly once on teardown.")
    }

    // MARK: - End-to-end proxy integration (opt-in, hits the public internet)

    /// Drives a real `StreamProxyServer` against a known-stable public HLS stream and asserts the
    /// behaviour any conventional player (VLC, hls.js, AVPlayer) relies on: the served manifest is
    /// non-cacheable, its URLs are rewritten back through the proxy, the media playlist is reachable
    /// through the proxy, and a segment actually downloads over the socket.
    ///
    /// If the stream is *live* (no `#EXT-X-ENDLIST`) it additionally asserts the media playlist
    /// advances across reloads — the exact property whose absence froze playback at ~16s. The
    /// default source is the long-lived Mux VOD test stream (stable), which exercises everything but
    /// advancement; point `POLLUX_TEST_HLS_URL` at a live source to also cover advancement.
    ///
    /// Opt-in because it depends on the network. Enable with `POLLUX_NETWORK_TESTS=1`.
    func testProxyServesRealHLSStreamEndToEnd() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POLLUX_NETWORK_TESTS"] == "1",
            "Set POLLUX_NETWORK_TESTS=1 to run network integration tests."
        )

        let masterURLString = ProcessInfo.processInfo.environment["POLLUX_TEST_HLS_URL"]
            ?? "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
        let masterURL = try XCTUnwrap(URL(string: masterURLString))

        let stream = ExtractedStream(
            sourcePageURL: masterURL,
            streamURL: masterURL,
            headers: [:],
            kind: .hls,
            cachedPlaylists: [:],
            notice: nil,
            session: nil // Force the plain URLSession path; no headless Chrome required.
        )
        let proxy = try StreamProxyServer(stream: stream)
        try await proxy.start()
        let entryURL = try await proxy.entryURL()
        let client = URLSession(configuration: .ephemeral)

        do {
            // 1. Master playlist: served OK, marked non-cacheable, and rewritten through the proxy.
            let (masterData, masterResp) = try await client.data(from: entryURL)
            let masterHTTP = try XCTUnwrap(masterResp as? HTTPURLResponse)
            XCTAssertEqual(masterHTTP.statusCode, 200)
            XCTAssertEqual(
                masterHTTP.value(forHTTPHeaderField: "Cache-Control"),
                "no-cache, no-store, must-revalidate"
            )
            let masterText = String(decoding: masterData, as: UTF8.self)
            let variantProxyURL = try XCTUnwrap(
                firstResourceURL(in: masterText),
                "master playlist exposed no variant/media URL"
            )
            XCTAssertEqual(variantProxyURL.host, entryURL.host, "referenced URLs must route back through the proxy")
            XCTAssertEqual(variantProxyURL.port, entryURL.port)

            // 2. Media playlist is reachable through the proxy and lists segments.
            let firstMedia = try await fetchText(client, variantProxyURL)
            XCTAssertTrue(firstMedia.uppercased().contains("#EXTINF"), "expected a media playlist with segments")

            // 2a. Live streams must ADVANCE across reloads (guards the ~16s freeze). Skipped for VOD.
            let isLive = !firstMedia.uppercased().contains("#EXT-X-ENDLIST")
            if isLive {
                let firstSequence = mediaSequenceNumber(firstMedia)
                try await Task.sleep(nanoseconds: 10_000_000_000) // let the live window roll
                let secondMedia = try await fetchText(client, variantProxyURL)
                XCTAssertTrue(
                    mediaSequenceNumber(secondMedia) > firstSequence || secondMedia != firstMedia,
                    "live media playlist did not advance across reloads — playback would freeze"
                )
            }

            // 3. A media segment downloads through the proxy.
            let segmentProxyURL = try XCTUnwrap(
                firstResourceURL(in: firstMedia),
                "media playlist exposed no segment URL"
            )
            let (segmentData, segmentResp) = try await client.data(from: segmentProxyURL)
            let segmentHTTP = try XCTUnwrap(segmentResp as? HTTPURLResponse)
            XCTAssertEqual(segmentHTTP.statusCode, 200)
            XCTAssertFalse(segmentData.isEmpty, "segment body was empty")
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }

    /// First non-comment, non-empty line of a playlist — a variant URL in a master, or a segment URL
    /// in a media playlist.
    private func firstResourceURL(in playlist: String) -> URL? {
        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            return URL(string: line)
        }
        return nil
    }

    private func mediaSequenceNumber(_ playlist: String) -> Int {
        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("#EXT-X-MEDIA-SEQUENCE:") else { continue }
            return Int(line.split(separator: ":").last.map(String.init) ?? "") ?? 0
        }
        return 0
    }

    private func fetchText(_ session: URLSession, _ url: URL) async throws -> String {
        let (data, _) = try await session.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeStream(session: BrowserSession) -> ExtractedStream {
        ExtractedStream(
            sourcePageURL: URL(string: "https://example.com/watch/1")!,
            streamURL: URL(string: "https://cdn.example.com/master.m3u8")!,
            headers: [:],
            kind: .hls,
            cachedPlaylists: [:],
            notice: nil,
            session: session
        )
    }

    func testMasterPlaylistSelectionOverVariantForLiveBroadcast() throws {
        let masterURL = try XCTUnwrap(URL(string: "https://cdn.example.com/secure/playlist.m3u8"))
        let variantURL = try XCTUnwrap(URL(string: "https://cdn.example.com/secure/high/mono.m3u8"))

        let masterCandidate = StreamCandidate(url: masterURL, headers: [:], kind: .hls, score: 100)
        let variantCandidate = StreamCandidate(url: variantURL, headers: [:], kind: .hls, score: 50)

        let cachedPlaylists: [String: String] = [
            masterURL.absoluteString: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000\nhigh/mono.m3u8",
            variantURL.absoluteString: "#EXTM3U\n#EXTINF:4.0,\nsegment1.ts\n#EXTINF:4.0,\nsegment2.ts"
        ]

        let selected = preferredPlaybackCandidates(
            from: [masterCandidate, variantCandidate],
            cachedPlaylists: cachedPlaylists
        )

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.url, masterURL)
    }

    // MARK: - Anti-automation mitigation (quiet-CDP path)

    private func testProfile() -> BrowserProfile {
        BrowserProfile(
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/133.0.0.0 Safari/537.36",
            acceptLanguage: "en-US,en;q=0.9",
            platform: "MacIntel",
            windowWidth: 1920,
            windowHeight: 1080
        )
    }

    func testLaunchArgumentsDropDisableWebSecurityWhenMitigationEnabled() {
        let dir = URL(fileURLWithPath: "/tmp/pollux-test-profile")

        let mitigated = ChromeBrowserSession.launchArguments(
            profile: testProfile(), userDataDirectory: dir, headful: false, mitigation: true
        )
        // The quiet path must not carry the `--disable-web-security` fingerprint.
        XCTAssertFalse(mitigated.contains("--disable-web-security"))
        // But it must still be headless and carry the automation-hiding flags.
        XCTAssertTrue(mitigated.contains("--headless=new"))
        XCTAssertTrue(mitigated.contains("--disable-blink-features=AutomationControlled"))

        let normal = ChromeBrowserSession.launchArguments(
            profile: testProfile(), userDataDirectory: dir, headful: false, mitigation: false
        )
        XCTAssertTrue(normal.contains("--disable-web-security"))
    }

    func testLaunchArgumentsHeadfulDropsHeadlessFlag() {
        let dir = URL(fileURLWithPath: "/tmp/pollux-test-profile")
        let headful = ChromeBrowserSession.launchArguments(
            profile: testProfile(), userDataDirectory: dir, headful: true, mitigation: true
        )
        XCTAssertFalse(headful.contains("--headless=new"))
    }

    func testHardenedStealthScriptPatchesKnownHeadlessTells() {
        let script = testProfile().hardenedStealthScript
        // Guards against silently dropping any of the fingerprints the quiet path is meant to fix.
        XCTAssertTrue(script.contains("PluginArray"), "must spoof plugins (empty is a headless tell)")
        XCTAssertTrue(script.contains("MimeTypeArray"), "must spoof mimeTypes")
        XCTAssertTrue(script.contains("outerWidth"), "must set window.outerWidth")
        XCTAssertTrue(script.contains("WebGL2RenderingContext"), "must spoof WebGL2, not just WebGL1")
        XCTAssertTrue(script.contains("[native code]"), "patched functions must report native toString()")
        XCTAssertTrue(script.contains("webdriver"), "must hide navigator.webdriver")
    }

    func testAntiAutomationLevelDefaultsOffAndResolvesRawValues() {
        let suiteName = "PolluxTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset must read as off — the feature is strictly opt-in.
        XCTAssertEqual(AntiAutomationLevel.resolved(from: defaults), .off)

        defaults.set(AntiAutomationLevel.standard.rawValue, forKey: PolluxPreferences.antiAutomationLevelKey)
        XCTAssertEqual(AntiAutomationLevel.resolved(from: defaults), .standard)
    }

    func testAntiAutomationLevelMigratesLegacyBoolean() {
        let suiteName = "PolluxTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A user who had the old boolean toggle on should land on the Standard level.
        defaults.set(true, forKey: PolluxPreferences.antiAutomationMitigationKey)
        XCTAssertEqual(AntiAutomationLevel.resolved(from: defaults), .standard)

        // An explicit new-key value always wins over the legacy boolean.
        defaults.set(AntiAutomationLevel.off.rawValue, forKey: PolluxPreferences.antiAutomationLevelKey)
        XCTAssertEqual(AntiAutomationLevel.resolved(from: defaults), .off)
    }

}

/// Records `close()` calls so tests can assert the proxy's session ownership semantics without
/// launching a real headless Chrome.
actor SpyBrowserSession: BrowserSession {
    private(set) var closeCount = 0

    func fetchTextResource(at url: URL, timeout: TimeInterval) async throws -> String { "" }
    func fetchBinaryResource(at url: URL, timeout: TimeInterval) async throws -> Data { Data() }
    func close() async { closeCount += 1 }
}
