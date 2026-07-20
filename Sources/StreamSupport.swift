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
        if let fromExtension = fromExtension(url.pathExtension) {
            return fromExtension
        }

        guard let mimeType else {
            return nil
        }

        return fromMIME(mimeType)
    }

    static func fromMIME(_ mimeType: String) -> StreamKind? {
        switch mimeType.lowercased() {
        case "audio/mpegurl", "audio/x-mpegurl", "application/x-mpegurl", "application/vnd.apple.mpegurl":
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

struct ExtractedStream: Sendable {
    let sourcePageURL: URL
    let streamURL: URL
    let headers: [String: String]
    let kind: StreamKind
    let cachedPlaylists: [String: String]
    let notice: String?
    let session: ChromeBrowserSession?

    init(
        sourcePageURL: URL,
        streamURL: URL,
        headers: [String: String],
        kind: StreamKind,
        cachedPlaylists: [String: String],
        notice: String?,
        session: ChromeBrowserSession? = nil
    ) {
        self.sourcePageURL = sourcePageURL
        self.streamURL = streamURL
        self.headers = headers
        self.kind = kind
        self.cachedPlaylists = cachedPlaylists
        self.notice = notice
        self.session = session
    }
}

enum PolluxPreferences {
    static let ffprobePathKey = "pollux.ffprobePath"
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
    let preferred = candidates.filter { !isMasterHLSCandidate($0, cachedPlaylists: cachedPlaylists) }
    return preferred.isEmpty ? candidates : preferred
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
                guard let absoluteURL = URL(string: attributeURL, relativeTo: playlistURL)?.absoluteURL,
                      StreamKind.detect(url: absoluteURL, mimeType: nil) == .hls,
                      seen.insert(absoluteURL.absoluteString).inserted
                else {
                    continue
                }
                discovered.append(absoluteURL)
            }
            continue
        }

        guard let absoluteURL = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL,
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

        guard let absoluteURL = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL else {
            return line
        }
        return proxyURL(absoluteURL).absoluteString
    }

    return Data(rewrittenLines.joined(separator: "\n").utf8)
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

enum ProxyURLBuilder {
    static func proxyURL(port: UInt16, targetURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/proxy/stream" + proxyExtension(for: targetURL.absoluteString)
        components.queryItems = [
            URLQueryItem(name: "url", value: targetURL.absoluteString),
        ]
        return components.url!
    }

    static func proxyExtension(for rawTargetURL: String) -> String {
        if let parsed = URL(string: rawTargetURL) {
            let pathExtension = parsed.pathExtension.lowercased()
            if !pathExtension.isEmpty {
                return ".\(pathExtension)"
            }
        }
        if rawTargetURL.lowercased().contains(".m3u8") {
            return ".m3u8"
        }
        return ".bin"
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

private func rewriteAttributeURIs(in line: String, playlistURL: URL, proxyURL: (URL) -> URL) -> String {
    let expression = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
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
        guard let absoluteURL = URL(string: rawValue, relativeTo: playlistURL)?.absoluteURL,
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
    let expression = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
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
