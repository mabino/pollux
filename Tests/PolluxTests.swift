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

    func testPreferredPlaybackCandidatesDropsMasterWhenVariantExists() throws {
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

        XCTAssertEqual(preferred.map { $0.url.absoluteString }, [variantURL.absoluteString])
    }

    func testPNGHeaderStripperLeavesNormalDataAndRemovesLeadingImage() {
        let payload = Data("video-segment".utf8)
        XCTAssertEqual(stripPNGHeaderIfNeeded(payload), payload)

        let pngHeader = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
        let wrapped = pngHeader + Data(repeating: 0x00, count: 8) + iend + payload
        XCTAssertEqual(stripPNGHeaderIfNeeded(wrapped), payload)
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
        let profile = BrowserProfile.random()
        let session = try await ChromeBrowserSession.launch(profile: profile) { _, _ in }
        defer { Task { await session.close() } }
        try await session.navigate(to: pageURL, timeout: 15)
        XCTAssertNotNil(session.currentURL)
    }
}
