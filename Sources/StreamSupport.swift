import Foundation

struct UserFacingError: Equatable, Sendable {
    let title: String
    let message: String
}

enum PolluxError: Error, Sendable {
    case invalidURL(String)
    case chromiumMissing
    case ffprobeMissing
    case browserLaunchFailed(String)
    case browserDidNotExposeDevTools
    case navigationTimedOut(URL)
    case noStreamCaptured(URL)
    case unsupportedFormats([String])
    case noPlayableStream
    case proxyStartFailed(String)
    case playbackFailed(String)
    case extractionTimedOut(URL, TimeInterval)
    case unexpected(String)
}

extension PolluxError {
    var userFacing: UserFacingError {
        switch self {
        case .invalidURL:
            return UserFacingError(
                title: "That URL doesn't look valid",
                message: "Enter a full http:// or https:// page URL so Pollux can open the player and look for its stream requests."
            )

        case .chromiumMissing:
            return UserFacingError(
                title: "Chromium couldn't be found",
                message: "Pollux uses the same Chrome-based extraction approach as Castor. Install Chromium or Google Chrome, or point POLLUX_CHROME_PATH at the browser executable."
            )

        case .ffprobeMissing:
            return UserFacingError(
                title: "ffprobe isn't available",
                message: "Pollux validates captured candidates with ffprobe before opening AVPlayer. Install ffprobe, choose Pollux > Settings… to save its path, or set POLLUX_FFPROBE_PATH to the executable."
            )

        case .browserLaunchFailed(let reason):
            return UserFacingError(
                title: "Pollux couldn't start its extraction browser",
                message: sanitizedReason(reason, fallback: "Chromium exited before Pollux could attach to its DevTools endpoint.")
            )

        case .browserDidNotExposeDevTools:
            return UserFacingError(
                title: "Chromium never exposed a debugging session",
                message: "Pollux launched the browser, but it never published a page target to inspect. Try again or set POLLUX_CHROME_PATH to a working Chromium or Chrome build."
            )

        case .navigationTimedOut(let url):
            return UserFacingError(
                title: "The page took too long to become ready",
                message: "Pollux opened \(url.absoluteString), but the player never reached a ready state in time."
            )

        case .noStreamCaptured:
            return UserFacingError(
                title: "Pollux couldn't find a playable stream",
                message: "The page loaded, but no HLS or MP4-style stream request showed up. The site may require more interaction, may have changed its player, or may be blocking automation."
            )

        case .unsupportedFormats(let formats):
            let joined = formats.joined(separator: ", ")
            return UserFacingError(
                title: "Pollux found a stream, but not one AVPlayer can use cleanly",
                message: "The extracted candidates were \(joined). This native player build works best with HLS and MP4."
            )

        case .noPlayableStream:
            return UserFacingError(
                title: "Pollux rejected the captured candidates",
                message: "Pollux saw stream-like URLs, but ffprobe marked them as decoys or missing real video and audio."
            )

        case .proxyStartFailed(let reason):
            return UserFacingError(
                title: "Pollux couldn't start its local playback proxy",
                message: sanitizedReason(reason, fallback: "The native player couldn't prepare its local stream bridge.")
            )

        case .playbackFailed(let reason):
            return UserFacingError(
                title: "The extracted stream couldn't be opened",
                message: sanitizedReason(reason, fallback: "AVPlayer rejected the extracted stream.")
            )

        case .extractionTimedOut(let url, let seconds):
            return UserFacingError(
                title: "Stream extraction timed out",
                message: "Extraction timed out after \(Int(seconds)) seconds for \(url.absoluteString). Check the Extraction Log under Window > Extraction Log for details."
            )

        case .unexpected(let reason):
            return UserFacingError(
                title: "Pollux hit an unexpected error",
                message: sanitizedReason(reason, fallback: "Something went wrong while extracting or preparing playback.")
            )
        }
    }
}

enum StreamKind: String, Sendable {
    case hls
    case mp4
    case mov
    case webm
    case mkv
    case avi

    var displayName: String {
        switch self {
        case .hls:
            return "HLS"
        case .mp4:
            return "MP4"
        case .mov:
            return "QuickTime"
        case .webm:
            return "WebM"
        case .mkv:
            return "Matroska"
        case .avi:
            return "AVI"
        }
    }

    var mimeType: String {
        switch self {
        case .hls:
            return "application/vnd.apple.mpegurl"
        case .mp4:
            return "video/mp4"
        case .mov:
            return "video/quicktime"
        case .webm:
            return "video/webm"
        case .mkv:
            return "video/x-matroska"
        case .avi:
            return "video/x-msvideo"
        }
    }

    var avPlayerSupported: Bool {
        switch self {
        case .hls, .mp4, .mov:
            return true
        case .webm, .mkv, .avi:
            return false
        }
    }

    static func detect(url: URL, mimeType: String?) -> StreamKind? {
        return detect(urlString: url.absoluteString, mimeType: mimeType)
    }

    static func detect(urlString: String, mimeType: String?) -> StreamKind? {
        let parsed = getPathAndExtension(from: urlString)
        if let fromExtension = fromExtension(parsed.pathExtension) {
            return fromExtension
        }

        guard let mimeType else {
            return nil
        }

        return fromMIME(mimeType)
    }

    static func fromMIME(_ mimeType: String) -> StreamKind? {
        switch mimeType.lowercased() {
        case "audio/mpegurl", "audio/x-mpegurl", "application/x-mpegurl", "application/vnd.apple.mpegurl", "video/mp2t", "video/ts":
            return .hls
        case "video/mp4", "application/mp4":
            return .mp4
        case "video/quicktime":
            return .mov
        case "video/webm":
            return .webm
        case "video/x-matroska":
            return .mkv
        case "video/x-msvideo":
            return .avi
        default:
            return nil
        }
    }

    static func fromFFprobeFormat(_ formatName: String) -> StreamKind? {
        for component in formatName.split(separator: ",") {
            switch component.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "hls", "applehttp":
                return .hls
            case "mp4":
                return .mp4
            case "mov":
                return .mov
            case "matroska":
                return .mkv
            case "webm":
                return .webm
            case "avi":
                return .avi
            default:
                continue
            }
        }
        return nil
    }

    private static func fromExtension(_ pathExtension: String) -> StreamKind? {
        switch pathExtension.lowercased() {
        case "m3u8":
            return .hls
        case "mp4", "m4v":
            return .mp4
        case "mov":
            return .mov
        case "webm":
            return .webm
        case "mkv":
            return .mkv
        case "avi":
            return .avi
        default:
            return nil
        }
    }
}

struct BrowserCookie: Sendable {
    let name: String
    let value: String
    let domain: String
}

struct CapturedEntry: Sendable {
    let rawURL: String
    let headers: [String: String]
    let mimeType: String?
    let score: Int
}

struct StreamCandidate: Sendable {
    let url: URL
    let headers: [String: String]
    let kind: StreamKind
    let score: Int
}

/// The subset of a live browser session the playback proxy depends on: authenticated resource
/// fetches for live playlist/segment refresh, plus teardown. Abstracted behind a protocol so the
/// proxy's session handling (notably ownership/close semantics) can be tested without launching
/// Chrome.
protocol BrowserSession: AnyObject, Sendable {
    func fetchTextResource(at url: URL, timeout: TimeInterval) async throws -> String
    func fetchBinaryResource(at url: URL, timeout: TimeInterval) async throws -> Data
    func close() async
}

struct ExtractedStream: Sendable {
    let sourcePageURL: URL
    let streamURL: URL
    let headers: [String: String]
    let kind: StreamKind
    let cachedPlaylists: [String: String]
    let excludedVariantURLs: Set<String>
    let notice: String?
    let session: BrowserSession?

    init(
        sourcePageURL: URL,
        streamURL: URL,
        headers: [String: String],
        kind: StreamKind,
        cachedPlaylists: [String: String],
        excludedVariantURLs: Set<String> = [],
        notice: String?,
        session: BrowserSession? = nil
    ) {
        self.sourcePageURL = sourcePageURL
        self.streamURL = streamURL
        self.headers = headers
        self.kind = kind
        self.cachedPlaylists = cachedPlaylists
        self.excludedVariantURLs = excludedVariantURLs
        self.notice = notice
        self.session = session
    }
}

enum PolluxPreferences {
    static let ffprobePathKey = "pollux.ffprobePath"
    /// When enabled, the Extraction Log includes a line for every CDP network request/response and
    /// console message. Off by default: that per-event firehose is only useful for deep debugging
    /// and is heavy on the UI. High-level pipeline milestones and errors are always logged.
    static let verboseExtractionLoggingKey = "pollux.verboseExtractionLogging"
    /// Total seconds extraction is allowed to keep retrying capture before giving up. A larger budget
    /// means more re-navigations against anti-bot pages that only occasionally render the real player.
    static let captureRetryBudgetKey = "pollux.captureRetryBudgetSeconds"
    /// Recently opened stream page URLs, backing the File ▸ Open Recent menu.
    static let recentStreamsKey = "pollux.recentStreams"
    /// Launch the extraction browser with a visible (headful) window instead of headless. Some sites
    /// detect headless Chromium and serve a black/blocked page; a real window can bypass that.
    static let headfulExtractionKey = "pollux.headfulExtraction"
    /// Close the extraction browser the moment a stream is selected. Frees the Chromium instance
    /// immediately, but live playlists then refresh via direct connections only (no browser fallback),
    /// which some CDNs reject — leave off if live playback stalls.
    static let releaseBrowserAfterExtractionKey = "pollux.releaseBrowserAfterExtraction"
    /// Legacy boolean predecessor of `antiAutomationLevelKey`. Retained only so an existing "on"
    /// setting migrates to `.standard`. New writes go to `antiAutomationLevelKey`.
    static let antiAutomationMitigationKey = "pollux.antiAutomationMitigation"
    /// Selects how hard Pollux works to avoid automation detection. Stores an `AntiAutomationLevel`
    /// raw value. Off by default. `.standard` is the "quiet CDP" path (skips `Runtime.enable`, isolated
    /// world probes, hardened stealth, no `--disable-web-security`).
    static let antiAutomationLevelKey = "pollux.antiAutomationLevel"
}

/// Anti-detection strategy. Backed by `PolluxPreferences.antiAutomationLevelKey`.
enum AntiAutomationLevel: Int, Sendable, CaseIterable {
    /// Standard CDP-driven extraction (fastest, most capable, most detectable).
    case off = 0
    /// "Quiet CDP": skip `Runtime.enable`, isolated-world probes, hardened stealth, no
    /// `--disable-web-security`. Defeats `Runtime.enable`-class detection.
    case standard = 1

    static func resolved(from defaults: UserDefaults = .standard) -> AntiAutomationLevel {
        // `object(forKey:) != nil` distinguishes "set" from "unset"; `integer(forKey:)` then coerces
        // both a stored Int (GUI @AppStorage) and a stored String (command-line `-key value`).
        if defaults.object(forKey: PolluxPreferences.antiAutomationLevelKey) != nil,
           let level = AntiAutomationLevel(rawValue: defaults.integer(forKey: PolluxPreferences.antiAutomationLevelKey)) {
            return level
        }
        // Migrate the retired boolean: a previously-enabled toggle maps to the quiet CDP path.
        if defaults.bool(forKey: PolluxPreferences.antiAutomationMitigationKey) {
            return .standard
        }
        return .off
    }
}

/// Resolves the user-configurable "how long to keep retrying capture" budget, with a safe default and
/// clamping. Extraction against adversarial sites is probabilistic, so this trades wall-clock time for
/// a higher chance of catching a good page load.
enum CaptureRetryBudget {
    static let minSeconds: TimeInterval = 30
    static let maxSeconds: TimeInterval = 300
    static let defaultSeconds: TimeInterval = 60

    static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(maxSeconds, max(minSeconds, seconds))
    }

    static func resolved(from userDefaults: UserDefaults = .standard) -> TimeInterval {
        // `object(forKey:)` distinguishes "unset" (use default) from an explicit 0.
        guard let stored = userDefaults.object(forKey: PolluxPreferences.captureRetryBudgetKey) as? Double else {
            return defaultSeconds
        }
        return clamp(stored)
    }
}

func parsePageURL(_ rawValue: String) throws -> URL {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
        let url = URL(string: trimmed),
        let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        url.host?.isEmpty == false
    else {
        throw PolluxError.invalidURL(rawValue)
    }
    return url
}

func locateExecutable(
    envName: String,
    defaultsKey: String? = nil,
    preferredPaths: [String] = [],
    fallbackNames: [String] = [],
    userDefaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL? {
    var candidates: [String] = []
    if let overridePath = environment[envName], !overridePath.isEmpty {
        candidates.append(overridePath)
    }
    if let defaultsKey, let savedPath = storedExecutableOverride(forKey: defaultsKey, userDefaults: userDefaults) {
        candidates.append(savedPath)
    }
    candidates.append(contentsOf: preferredPaths)

    let pathEntries = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    for fallbackName in fallbackNames {
        for pathEntry in pathEntries {
            let candidatePath = URL(fileURLWithPath: pathEntry)
                .appendingPathComponent(fallbackName)
                .path
            candidates.append(candidatePath)
        }
    }

    let fileManager = FileManager.default
    for candidate in candidates {
        if let resolved = resolveExecutableCandidate(candidate, fileManager: fileManager) {
            return resolved
        }
    }
    return nil
}

func locateChromiumExecutable(
    userDefaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL? {
    locateExecutable(
        envName: "POLLUX_CHROME_PATH",
        preferredPaths: [
            "/Applications/Chromium.app",
            "/Applications/Google Chrome.app",
            "/Applications/Google Chrome for Testing.app",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        ],
        fallbackNames: ["chromium", "google-chrome", "chrome"],
        userDefaults: userDefaults,
        environment: environment
    )
}

func storedExecutableOverride(forKey key: String, userDefaults: UserDefaults = .standard) -> String? {
    guard let rawValue = userDefaults.string(forKey: key) else {
        return nil
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func resolveExecutablePath(_ rawPath: String, fileManager: FileManager = .default) -> URL? {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    return resolveExecutableCandidate(trimmed, fileManager: fileManager)
}

func canonicalizedHeaders(_ captured: [String: String], sourcePageURL: URL, userAgent: String) -> [String: String] {
    var cleaned: [String: String] = [:]
    for (name, value) in captured where !name.hasPrefix(":") && name.lowercased() != "host" {
        cleaned[canonicalHTTPHeaderName(name)] = value
    }

    if cleaned["User-Agent"] == nil {
        cleaned["User-Agent"] = userAgent
    }
    if cleaned["Referer"] == nil {
        cleaned["Referer"] = sourcePageURL.absoluteString
    }
    if cleaned["Origin"] == nil, let scheme = sourcePageURL.scheme, let host = sourcePageURL.host {
        cleaned["Origin"] = "\(scheme)://\(host)"
    }
    return cleaned
}

func cookiesHeader(for url: URL, cookies: [BrowserCookie]) -> String {
    cookies
        .filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = url.host?.lowercased() ?? ""
            return !domain.isEmpty && (host == domain || host.hasSuffix(".\(domain)"))
        }
        .map { "\($0.name)=\($0.value)" }
        .joined(separator: "; ")
}

func shouldServeCachedPlaylist(_ playlist: String) -> Bool {
    let uppercased = playlist.uppercased()
    return uppercased.contains("#EXT-X-STREAM-INF") || uppercased.contains("#EXT-X-ENDLIST")
}

/// Response headers for a proxied HLS manifest. The manifest is always marked non-cacheable: a live
/// media playlist is a sliding window, so the player must re-request it on every reload to discover
/// new segments. Without these headers AVPlayer/ffplay cache the first window and playback freezes
/// once it is consumed.
func hlsManifestResponseHeaders(contentLength: Int, baseHeaders: [String: String] = [:]) -> [String: String] {
    var headers = baseHeaders
    headers["Content-Type"] = StreamKind.hls.mimeType
    headers["Content-Length"] = "\(contentLength)"
    headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    headers["Pragma"] = "no-cache"
    headers["Expires"] = "0"
    return headers
}

/// Whether a manifest whose live refresh failed upstream should fall back to the copy captured at
/// extraction time instead of surfacing the upstream response to the player. These CDNs routinely
/// reject direct fetches with 403 (only the authenticated browser session is allowed); such an error
/// — or an empty body — must never reach the player as if it were a real playlist.
func shouldServeCachedManifestOnUpstreamFailure(
    isPlaylist: Bool,
    upstreamStatus: Int,
    bodyIsEmpty: Bool,
    hasCachedCopy: Bool
) -> Bool {
    guard isPlaylist, hasCachedCopy else {
        return false
    }
    let upstreamOK = (upstreamStatus == 200 || upstreamStatus == 206) && !bodyIsEmpty
    return !upstreamOK
}

func isMasterHLSPlaylist(_ playlist: String) -> Bool {
    playlist.uppercased().contains("#EXT-X-STREAM-INF")
}

func isMasterHLSCandidate(_ candidate: StreamCandidate, cachedPlaylists: [String: String]) -> Bool {
    guard candidate.kind == .hls, let playlist = cachedPlaylists[candidate.url.absoluteString] else {
        return false
    }
    return isMasterHLSPlaylist(playlist)
}

func preferredPlaybackCandidates(
    from candidates: [StreamCandidate],
    cachedPlaylists: [String: String]
) -> [StreamCandidate] {
    let masters = candidates.filter { isMasterHLSCandidate($0, cachedPlaylists: cachedPlaylists) }
    return masters.isEmpty ? candidates : masters
}

func referencedHLSPlaylistURLs(in playlist: String, playlistURL: URL) -> [URL] {
    let source = playlist.replacingOccurrences(of: "\r\n", with: "\n")
    var discovered: [URL] = []
    var seen = Set<String>()

    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            continue
        }

        if trimmed.hasPrefix("#") {
            for attributeURL in attributeURIValues(in: trimmed) {
                guard let absoluteURL = safeURL(from: attributeURL, relativeTo: playlistURL)?.absoluteURL,
                      StreamKind.detect(url: absoluteURL, mimeType: nil) == .hls,
                      seen.insert(absoluteURL.absoluteString).inserted
                else {
                    continue
                }
                discovered.append(absoluteURL)
            }
            continue
        }

        guard let absoluteURL = safeURL(from: trimmed, relativeTo: playlistURL)?.absoluteURL,
              StreamKind.detect(url: absoluteURL, mimeType: nil) == .hls,
              seen.insert(absoluteURL.absoluteString).inserted
        else {
            continue
        }
        discovered.append(absoluteURL)
    }

    return discovered
}

func rewritePlaylistData(_ data: Data, playlistURL: URL, proxyURL: (URL) -> URL) throws -> Data {
    let source = String(decoding: data, as: UTF8.self)
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)

    let rewrittenLines = lines.map { rawLine -> String in
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return line
        }

        if trimmed.hasPrefix("#") {
            return rewriteAttributeURIs(in: line, playlistURL: playlistURL, proxyURL: proxyURL)
        }

        guard let absoluteURL = safeURL(from: trimmed, relativeTo: playlistURL)?.absoluteURL else {
            return line
        }
        return proxyURL(absoluteURL).absoluteString
    }

    return Data(rewrittenLines.joined(separator: "\n").utf8)
}

func filterExcludedVariantsFromMasterPlaylist(_ data: Data, playlistURL: URL, excludedVariantURLs: Set<String>) -> Data {
    guard !excludedVariantURLs.isEmpty else {
        return data
    }

    let source = String(decoding: data, as: UTF8.self)
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)

    var filtered: [String] = []
    var pendingVariantTag: String?

    for rawLine in lines {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let pendingVariantTagValue = pendingVariantTag {
            guard !trimmed.isEmpty,
                  let absoluteURL = safeURL(from: trimmed, relativeTo: playlistURL)?.absoluteURL
            else {
                filtered.append(pendingVariantTagValue)
                filtered.append(line)
                pendingVariantTag = nil
                continue
            }

            if excludedVariantURLs.contains(absoluteURL.absoluteString) {
                pendingVariantTag = nil
                continue
            }

            filtered.append(pendingVariantTagValue)
            filtered.append(line)
            pendingVariantTag = nil
            continue
        }

        if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
            pendingVariantTag = line
            continue
        }

        if trimmed.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") || trimmed.hasPrefix("#EXT-X-MEDIA") {
            let attributeURLs = attributeURIValues(in: line)
                .compactMap { safeURL(from: $0, relativeTo: playlistURL)?.absoluteURL.absoluteString }
            if attributeURLs.contains(where: excludedVariantURLs.contains) {
                continue
            }
        }

        filtered.append(line)
    }

    if let pendingVariantTag {
        filtered.append(pendingVariantTag)
    }

    return Data(filtered.joined(separator: "\n").utf8)
}

func stripPNGHeaderIfNeeded(_ data: Data) -> Data {
    guard looksLikePNG(data) else {
        return data
    }

    let iendSignature = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
    guard let endRange = data.range(of: iendSignature) else {
        return data
    }
    return data[endRange.upperBound...]
}

func decodeBase64DataURL(_ rawValue: String) -> Data? {
    guard let commaIndex = rawValue.firstIndex(of: ",") else {
        return nil
    }
    let metadata = rawValue[..<commaIndex].lowercased()
    guard metadata.hasPrefix("data:"), metadata.contains(";base64") else {
        return nil
    }
    let payloadStart = rawValue.index(after: commaIndex)
    return Data(base64Encoded: String(rawValue[payloadStart...]))
}

enum ProxyURLBuilder {
    static func proxyURL(port: UInt16, targetURL: URL, host: String = "127.0.0.1") -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/proxy/stream" + proxyExtension(for: targetURL.absoluteString)
        components.queryItems = [
            URLQueryItem(name: "url", value: targetURL.absoluteString),
        ]
        return components.url!
    }

    /// Real media-segment container extensions a player's HLS demuxer accepts as-is. Anything else —
    /// no extension, images, or obfuscated disguises like `.json`/`.php` (segments are commonly
    /// MPEG-TS dressed up to dodge filters) — is normalized to `.ts`. HLS demuxers (ffmpeg's
    /// `allowed_extensions`, AVFoundation) reject unknown segment extensions outright, which breaks
    /// playback even when the bytes are valid TS.
    private static let mediaSegmentExtensions: Set<String> = [
        "ts", "mp4", "m4s", "m4v", "m4a", "mp4a", "aac", "mp3", "ac3", "ec3", "vtt", "webvtt",
    ]

    static func proxyExtension(for rawTargetURL: String) -> String {
        let parsed = getPathAndExtension(from: rawTargetURL)
        let pathExtension = parsed.pathExtension.lowercased()

        if pathExtension == "m3u8" || rawTargetURL.lowercased().contains(".m3u8") {
            return ".m3u8"
        }
        if pathExtension == "key" || pathExtension == "bin" {
            return ".\(pathExtension)"
        }
        if mediaSegmentExtensions.contains(pathExtension) {
            return ".\(pathExtension)"
        }

        return ".ts"
    }
}

func proxyContentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "ts":
        return "video/mp2t"
    case "mp4", "m4v", "m4s":
        return "video/mp4"
    case "aac":
        return "audio/aac"
    default:
        return "application/octet-stream"
    }
}

private func resolveExecutableCandidate(_ candidate: String, fileManager: FileManager) -> URL? {
    let expanded = (candidate as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return nil
    }

    if isDirectory.boolValue {
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let executableURL = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executableURL.path)
        else {
            return nil
        }
        return executableURL
    }

    return fileManager.isExecutableFile(atPath: url.path) ? url : nil
}

private func canonicalHTTPHeaderName(_ rawName: String) -> String {
    rawName
        .split(separator: "-")
        .map { component in
            component.prefix(1).uppercased() + component.dropFirst().lowercased()
        }
        .joined(separator: "-")
}

/// `URI="…"` attribute value inside an HLS tag (e.g. `#EXT-X-KEY`, `#EXT-X-MEDIA`). Compiled once and
/// reused, since it is applied to every line of every playlist that flows through the proxy.
private let attributeURIRegex = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)

private func rewriteAttributeURIs(in line: String, playlistURL: URL, proxyURL: (URL) -> URL) -> String {
    let expression = attributeURIRegex
    let nsLine = line as NSString
    let matches = expression.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
    guard !matches.isEmpty else {
        return line
    }

    var rewritten = line
    for match in matches.reversed() {
        let attributeRange = match.range
        let valueRange = match.range(at: 1)
        let rawValue = nsLine.substring(with: valueRange)
        guard let absoluteURL = safeURL(from: rawValue, relativeTo: playlistURL)?.absoluteURL,
              let replacementRange = Range(attributeRange, in: rewritten)
        else {
            continue
        }
        let replacement = #"URI="\#(proxyURL(absoluteURL).absoluteString)""#
        rewritten.replaceSubrange(replacementRange, with: replacement)
    }
    return rewritten
}

private func attributeURIValues(in line: String) -> [String] {
    let expression = attributeURIRegex
    let nsLine = line as NSString
    let matches = expression.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
    return matches.compactMap { match in
        guard match.numberOfRanges > 1 else {
            return nil
        }
        return nsLine.substring(with: match.range(at: 1))
    }
}

private func looksLikePNG(_ data: Data) -> Bool {
    let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    return data.starts(with: pngSignature)
}

func sanitizedReason(_ rawReason: String, fallback: String) -> String {
    let trimmed = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return fallback
    }

    if trimmed.count <= 240 {
        return trimmed
    }
    return String(trimmed.prefix(237)) + "..."
}

func safeURL(from string: String) -> URL? {
    // Strip surrounding whitespace, control characters, and stray backslashes before parsing. A literal
    // backslash is never valid in a URL — it slips in from shell-escaped (`\?`, `\=`, `\&`) or copy-pasted
    // links. Left in place it can't be parsed, so the fallback below percent-encodes it to `%5C`, which
    // silently corrupts the path/query (e.g. `.html%5C?icg%5C=…`) and navigates to the wrong page while
    // still appearing to "load."
    let cleaned = String(String.UnicodeScalarView(string.unicodeScalars.filter { scalar in
        scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
    })).trimmingCharacters(in: .whitespacesAndNewlines)

    if let url = URL(string: cleaned) {
        return url
    }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.formUnion(CharacterSet.urlPathAllowed)
    allowed.formUnion(CharacterSet.urlHostAllowed)
    allowed.formUnion(CharacterSet.urlUserAllowed)
    allowed.formUnion(CharacterSet.urlPasswordAllowed)
    if let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: allowed) {
        return URL(string: encoded)
    }
    return nil
}

func safeURL(from string: String, relativeTo baseURL: URL) -> URL? {
    if let url = URL(string: string, relativeTo: baseURL) {
        return url
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    var absoluteString = trimmed
    if trimmed.starts(with: "//") {
        absoluteString = (baseURL.scheme ?? "https") + ":" + trimmed
    } else if !trimmed.contains("://") {
        if trimmed.starts(with: "/") {
            if let host = baseURL.host {
                let portStr = baseURL.port.map { ":\($0)" } ?? ""
                let scheme = baseURL.scheme ?? "https"
                absoluteString = "\(scheme)://\(host)\(portStr)\(trimmed)"
            }
        } else {
            var baseParts = baseURL.path.split(separator: "/")
            if !baseParts.isEmpty && !baseURL.path.hasSuffix("/") {
                baseParts.removeLast()
            }
            let basePath = baseParts.isEmpty ? "" : "/" + baseParts.joined(separator: "/")
            let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
            if let host = baseURL.host {
                let portStr = baseURL.port.map { ":\($0)" } ?? ""
                let scheme = baseURL.scheme ?? "https"
                absoluteString = "\(scheme)://\(host)\(portStr)\(prefix)\(trimmed)"
            }
        }
    }
    return safeURL(from: absoluteString)
}

func getPathAndExtension(from urlString: String) -> (path: String, pathExtension: String) {
    let base = urlString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? urlString
    let stripped = base.split(separator: "#", maxSplits: 1).first.map(String.init) ?? base
    var path = stripped
    if let schemeRange = stripped.range(of: "://") {
        let rest = stripped[schemeRange.upperBound...]
        if let firstSlash = rest.firstIndex(of: "/") {
            path = String(rest[firstSlash...])
        } else {
            path = "/"
        }
    }
    let lastPathComponent = path.split(separator: "/").last.map(String.init) ?? ""
    let parts = lastPathComponent.split(separator: ".")
    let pathExtension = parts.count > 1 ? String(parts.last!) : ""
    return (path, pathExtension)
}

// MARK: - Capture scoring & ordering

/// Heuristic score for how good an HLS URL is as a playback entry point, judged from its path shape:
/// a master playlist (+100) is preferred over a media/variant playlist (+50), and an individual quality
/// rendition or segment path (−50) is penalized. Shared by the live network capture collector and the
/// cached-playlist candidate builder so both rank URLs by exactly the same rule.
func hlsCandidateScore(forURLString rawURL: String) -> Int {
    let path = getPathAndExtension(from: rawURL).path.lowercased()
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

/// Canonical "best candidate first" ordering: higher score wins, and on a tie the lexicographically
/// smaller URL wins so the result is stable and deterministic across runs. Used everywhere capture
/// candidates are sorted or reduced to a single best pick.
func isBetterCandidate(scoreL: Int, urlL: String, scoreR: Int, urlR: String) -> Bool {
    if scoreL != scoreR {
        return scoreL > scoreR
    }
    return urlL < urlR
}

// MARK: - Polling

/// Polls `condition` every `interval` seconds until it returns true or `deadline` passes, returning
/// whether it became true in time. Honors task cancellation (throws `CancellationError`) so a caller
/// running inside an extraction timeout budget unwinds promptly. Replaces the hand-rolled
/// `while Date() < deadline { … Task.sleep }` loops used for pure-condition waits.
func waitUntil(
    deadline: Date,
    interval: TimeInterval,
    _ condition: () async -> Bool
) async throws -> Bool {
    while Date() < deadline {
        try Task.checkCancellation()
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return false
}

// MARK: - Browser fetch sentinel

/// Prefix of the sentinel string an in-page `fetch` helper returns when it fails. A CDP
/// `Runtime.evaluate` can only hand back a string, so failures are signaled as `"ERROR: …"` rather
/// than thrown. Both the session's fetch helpers and the proxy's browser-fetch fallback key on this.
let browserFetchErrorPrefix = "ERROR:"

/// True when a browser-side fetch returned the failure sentinel instead of the resource body.
func isBrowserFetchError(_ text: String) -> Bool {
    text.hasPrefix(browserFetchErrorPrefix)
}

/// True when `text` is an actual HLS playlist (contains the `#EXTM3U` tag) rather than something a
/// failed fetch can return that is still non-empty and not the `"ERROR:"` sentinel — most importantly
/// an HTTP 403/404 error page. Without this check the proxy would relabel that error HTML as a `200`
/// playlist and rewrite its lines into bogus segments, permanently stalling playback instead of
/// letting the graceful cached-copy fallback (and the player's next reload) recover.
func looksLikeHLSPlaylistText(_ text: String) -> Bool {
    text.uppercased().contains("#EXTM3U")
}

// MARK: - Stream URL harvesting patterns

/// Matches an absolute `.m3u8` URL anywhere in text (e.g. a console log line or an API JSON body).
let m3u8Regex = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+\.m3u8[^\s"'<>]*"#)
/// Matches an HLS URL embedded in API JSON that lives under an `/hls/` or `/live/` path without a
/// `.m3u8` suffix — some players are handed a suffix-less manifest URL.
let hlsURLRegex = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+/(?:hls|live)/[^\s"'<>]*"#)

extension NSRegularExpression {
    /// All full-match substrings of `text`, in order. Convenience over the range-based CoreFoundation API.
    func matches(in text: String) -> [String] {
        let nsText = text as NSString
        let results = matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return results.map { nsText.substring(with: $0.range) }
    }
}
