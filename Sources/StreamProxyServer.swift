import Foundation
import Network

actor StreamProxyServer {
    private let stream: ExtractedStream
    private let ownsSession: Bool
    private let listener: NWListener
    /// Host embedded in the proxied URLs handed to the player. The Mac's LAN IP when available, so
    /// AirPlay receivers (which fetch HLS themselves and can't reach 127.0.0.1) can load the stream;
    /// falls back to loopback when offline.
    private let advertisedHost: String
    private let queue = DispatchQueue(label: "io.github.mabino.pollux.proxy")
    private let session: URLSession

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var started = false

    /// - Parameter ownsSession: Whether stopping this proxy should also close the shared Chrome
    ///   browser session. The playback proxy owns the session (closing it tears down Chrome when
    ///   playback ends). Short-lived proxies that merely borrow the session for validation must set
    ///   this to `false`; otherwise they kill the session that live playlist refresh depends on.
    init(stream: ExtractedStream, ownsSession: Bool = true) throws {
        self.stream = stream
        self.ownsSession = ownsSession
        self.advertisedHost = primaryIPv4Address() ?? "127.0.0.1"

        // Bind on all interfaces (not just loopback) so an Apple TV on the LAN can reach the proxy.
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: .any)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func start() async throws {
        guard !started else {
            return
        }
        started = true

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleListenerState(state)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task {
                await self.accept(connection)
            }
        }

        listener.start(queue: queue)

        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    func entryURL() throws -> URL {
        try proxyURL(for: stream.streamURL)
    }

    func stop() {
        listener.cancel()
        let existingConnections = connections.values
        connections.removeAll()
        existingConnections.forEach { $0.cancel() }
        session.invalidateAndCancel()
        if ownsSession {
            let browserSession = stream.session
            Task {
                await browserSession?.close()
            }
        }

        if let readyContinuation {
            readyContinuation.resume(throwing: PolluxError.proxyStartFailed("The local proxy stopped before it was ready."))
            self.readyContinuation = nil
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil

        case .failed(let error):
            readyContinuation?.resume(throwing: PolluxError.proxyStartFailed(error.localizedDescription))
            readyContinuation = nil
            stop()

        case .cancelled:
            if let readyContinuation {
                readyContinuation.resume(throwing: PolluxError.proxyStartFailed("The local proxy was cancelled."))
                self.readyContinuation = nil
            }

        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) async {
        let identifier = UUID()
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task {
                    await self.removeConnection(identifier)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        defer {
            connection.cancel()
            removeConnection(identifier)
        }

        let responseData: Data
        do {
            let request = try await receiveRequest(on: connection)
            responseData = try await buildResponse(for: request)
        } catch let error as PolluxError {
            responseData = buildErrorResponse(statusCode: 500, message: error.userFacing.message)
        } catch {
            responseData = buildErrorResponse(statusCode: 500, message: error.localizedDescription)
        }

        try? await send(responseData, over: connection)
    }

    private func receiveRequest(on connection: NWConnection) async throws -> ProxyRequest {
        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)

        while buffer.range(of: delimiter) == nil {
            let chunk = try await receiveChunk(on: connection)
            guard !chunk.isEmpty else {
                throw PolluxError.proxyStartFailed("The playback proxy received an empty request.")
            }
            buffer.append(chunk)
            if buffer.count > 64 * 1024 {
                throw PolluxError.proxyStartFailed("The playback proxy received an unexpectedly large request header.")
            }
        }

        guard let headerRange = buffer.range(of: delimiter) else {
            throw PolluxError.proxyStartFailed("The playback proxy could not parse the incoming request.")
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw PolluxError.proxyStartFailed("The playback proxy could not decode the incoming request headers.")
        }

        return try ProxyRequest.parse(headerText)
    }

    private func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }

                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }

                continuation.resume(returning: Data())
            }
        }
    }

    private func send(_ responseData: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: responseData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func buildResponse(for request: ProxyRequest) async throws -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return buildErrorResponse(statusCode: 405, message: "Method not allowed")
        }

        guard let localPort = listener.port?.rawValue else {
            throw PolluxError.proxyStartFailed("The playback proxy does not have a bound port yet.")
        }

        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        guard let targetValue = components?.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetURL = safeURL(from: targetValue)
        else {
            return buildErrorResponse(statusCode: 400, message: "Missing or invalid target URL")
        }

        let isTargetURLPlaylist = targetURL.pathExtension.lowercased() == "m3u8" || request.url.path.lowercased().hasSuffix(".m3u8")

        // Cookie-authorized streams need the browser session's page context to fetch playlists/segments
        // (the CDN rejects a direct request without the session cookie). Token-authorized streams carry
        // their auth in the URL and are fetchable directly, so the browser round-trip is pure overhead.
        let streamUsesCookieAuth = stream.headers.contains { $0.key.lowercased() == "cookie" && !$0.value.isEmpty }

        if isTargetURLPlaylist {
            // Master playlists (and explicitly finished VOD playlists) are static indexes, so
            // it is safe to pin them to the browser-extraction cache. Live media playlists are
            // sliding windows: they MUST be refetched on every reload so the player keeps
            // discovering new segments. Serving a live media playlist from cache — or letting the
            // client cache it — freezes playback once the initial window is consumed.
            if let cachedPlaylist = stream.cachedPlaylists[targetURL.absoluteString], shouldServeCachedPlaylist(cachedPlaylist) {
                return try playlistResponse(
                    from: Data(cachedPlaylist.utf8),
                    playlistURL: targetURL,
                    localPort: localPort,
                    method: request.method
                )
            }

            // Only pay for a browser-context playlist fetch when the stream is cookie-authorized. A
            // token-authorized stream (auth carried in the URL, no Cookie header) is fetchable directly,
            // and the browser fetch merely fails cross-origin ("Failed to fetch") on every reload before
            // the direct URLSession path below succeeds — so we skip it. The browser fallback further
            // down still covers a failed direct fetch for either kind.
            if streamUsesCookieAuth, let browserSession = stream.session {
                do {
                    let fetchedText = try await browserSession.fetchTextResource(at: targetURL, timeout: 6)
                    print("[Proxy] Live playlist fetchTextResource returned length=\(fetchedText.count) prefix=\(String(fetchedText.prefix(40)))")
                    if !fetchedText.isEmpty && !isBrowserFetchError(fetchedText) && looksLikeHLSPlaylistText(fetchedText) {
                        return try playlistResponse(
                            from: Data(fetchedText.utf8),
                            playlistURL: targetURL,
                            localPort: localPort,
                            method: request.method
                        )
                    }
                } catch {
                    print("[Proxy] Live playlist fetchTextResource threw error: \(error.localizedDescription)")
                }
            }

            // The browser session was skipped or could not deliver a fresh playlist. Fall through to a
            // direct URLSession fetch below (with the captured stream headers) so the live window is
            // still refreshed. The stale cached copy is only used as a last resort, further down.
        }

        var upstreamRequest = URLRequest(url: targetURL)
        upstreamRequest.httpMethod = request.method
        applyCapturedHeaders(to: &upstreamRequest, downstreamHeaders: request.headers)

        print("[Proxy] Requesting upstream method=\(request.method) url=\(targetURL) headers=\(upstreamRequest.allHTTPHeaderFields ?? [:])")
        
        var responseBodyData: Data = Data()
        var httpResponse: HTTPURLResponse?
        
        do {
            let (body, urlResponse) = try await session.data(for: upstreamRequest)
            if let httpResp = urlResponse as? HTTPURLResponse {
                responseBodyData = body
                httpResponse = httpResp
            }
        } catch {
            print("[Proxy] URLSession request failed with error: \(error.localizedDescription)")
        }
        
        let statusCode = httpResponse?.statusCode ?? 500
        print("[Proxy] Upstream status=\(statusCode) url=\(targetURL)")

        let contentType = httpResponse?.allHeaderFields["Content-Type"] as? String ?? ""
        let isPlaylist =
            targetURL.pathExtension.lowercased() == "m3u8" ||
            request.url.path.lowercased().hasSuffix(".m3u8") ||
            contentType.lowercased().contains("mpegurl")

        // Fall back to browser session if URLSession failed (e.g. 403 Forbidden, 401 Unauthorized, or complete failure)
        if (statusCode != 200 && statusCode != 206) || responseBodyData.isEmpty, let browserSession = stream.session {
            if isPlaylist {
                if let browserFetchedText = try? await browserSession.fetchTextResource(at: targetURL, timeout: 6),
                   !browserFetchedText.isEmpty,
                   !isBrowserFetchError(browserFetchedText),
                   looksLikeHLSPlaylistText(browserFetchedText)
                {
                    print("[Proxy] Upstream failed with \(statusCode) via URLSession. Successfully fetched playlist text via browser.")
                    responseBodyData = Data(browserFetchedText.utf8)
                    httpResponse = HTTPURLResponse(
                        url: targetURL,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": "application/x-mpegurl",
                            "Content-Length": "\(responseBodyData.count)"
                        ]
                    )
                }
            } else {
                if let browserFetchedBody = try? await browserSession.fetchBinaryResource(at: targetURL, timeout: 6) {
                    print("[Proxy] Upstream failed with \(statusCode) via URLSession. Successfully fetched binary resource via browser.")
                    responseBodyData = browserFetchedBody
                    httpResponse = HTTPURLResponse(
                        url: targetURL,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": proxyContentType(for: request.url),
                            "Content-Length": "\(responseBodyData.count)"
                        ]
                    )
                }
            }
        }

        // Last resort for a live playlist whose live refresh failed on every path: fall back to
        // the copy captured during extraction so playback degrades gracefully instead of dying.
        // This is critical because these CDNs routinely reject a direct URLSession fetch with 403
        // (only the authenticated browser session is allowed). We must never surface that 403 — or
        // an empty/error body — to the player as if it were a real playlist. The no-cache headers on
        // the cached response keep the player polling, so it can recover as soon as a later reload
        // succeeds.
        let finalStatus = httpResponse?.statusCode ?? 0
        // Only fall back to a cached copy that is an actual playlist. Guarding here as well as at the
        // caching step means a stale HTML error page can never be served as bogus segments — the player
        // gets the honest upstream failure and can retry, rather than spinning on garbage forever.
        let cachedCopy = stream.cachedPlaylists[targetURL.absoluteString].flatMap {
            looksLikeHLSPlaylistText($0) ? $0 : nil
        }
        if shouldServeCachedManifestOnUpstreamFailure(
               isPlaylist: isPlaylist,
               upstreamStatus: finalStatus,
               bodyIsEmpty: responseBodyData.isEmpty,
               hasCachedCopy: !(cachedCopy?.isEmpty ?? true)
           ),
           let cachedPlaylist = cachedCopy {
            print("[Proxy] Live playlist refresh failed (status=\(finalStatus)); serving cached copy as last resort.")
            return try playlistResponse(
                from: Data(cachedPlaylist.utf8),
                playlistURL: targetURL,
                localPort: localPort,
                method: request.method
            )
        }

        guard let finalResponse = httpResponse else {
            throw PolluxError.proxyStartFailed("The upstream stream server returned an invalid response.")
        }

        // Only rewrite a playlist body when the upstream actually returned one (2xx). A failed playlist
        // fetch with no valid cached fallback must surface its real error status with the raw body — not
        // be run through the rewriter, which would turn an HTML error page into bogus segment URLs.
        if isPlaylist, finalResponse.statusCode == 200 || finalResponse.statusCode == 206 {
            return try playlistResponse(
                from: responseBodyData,
                playlistURL: targetURL,
                localPort: localPort,
                method: request.method,
                statusCode: finalResponse.statusCode,
                baseHeaders: filteredHeaders(from: finalResponse, bodyRewritten: true)
            )
        }

        let rewrittenBody = stripPNGHeaderIfNeeded(responseBodyData)
        var headers = filteredHeaders(from: finalResponse, bodyRewritten: rewrittenBody.count != responseBodyData.count)
        if headers["Content-Type"] == nil || headers["Content-Type"]?.lowercased().contains("octet-stream") == true || headers["Content-Type"]?.lowercased().contains("image") == true {
            headers["Content-Type"] = proxyContentType(for: request.url)
        }
        headers["Content-Length"] = "\(rewrittenBody.count)"

        let proxyResponse = ProxyResponse(
            statusCode: finalResponse.statusCode,
            headers: headers,
            body: request.method == "HEAD" ? Data() : rewrittenBody
        )
        return proxyResponse.encoded()
    }

    /// Builds a proxied HLS playlist response. The playlist is filtered (excluded variants),
    /// rewritten so every referenced URL points back through this proxy, and — critically —
    /// tagged with aggressive no-cache headers. Without these, AVPlayer / ffplay cache the live
    /// media playlist and stop reloading it, freezing playback once the initial window is played.
    private func playlistResponse(
        from data: Data,
        playlistURL: URL,
        localPort: UInt16,
        method: String,
        statusCode: Int = 200,
        baseHeaders: [String: String] = [:]
    ) throws -> Data {
        let filtered = filterExcludedVariantsFromMasterPlaylist(
            data,
            playlistURL: playlistURL,
            excludedVariantURLs: stream.excludedVariantURLs
        )
        let rewritten = try rewritePlaylistData(filtered, playlistURL: playlistURL) {
            ProxyURLBuilder.proxyURL(port: localPort, targetURL: $0, host: advertisedHost)
        }

        let headers = hlsManifestResponseHeaders(contentLength: rewritten.count, baseHeaders: baseHeaders)

        let proxyResponse = ProxyResponse(
            statusCode: statusCode,
            headers: headers,
            body: method == "HEAD" ? Data() : rewritten
        )
        return proxyResponse.encoded()
    }

    private func applyCapturedHeaders(to request: inout URLRequest, downstreamHeaders: [String: String]) {
        for (name, value) in stream.headers where shouldForwardRequestHeader(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = downstreamHeaders["Range"] {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        if let ifRange = downstreamHeaders["If-Range"] {
            request.setValue(ifRange, forHTTPHeaderField: "If-Range")
        }
    }

    private func filteredHeaders(from response: HTTPURLResponse, bodyRewritten: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let key = name as? String, shouldForwardResponseHeader(key, bodyRewritten: bodyRewritten) else {
                continue
            }
            headers[key] = String(describing: value)
        }
        return headers
    }

    private func proxyURL(for targetURL: URL) throws -> URL {
        guard let localPort = listener.port?.rawValue else {
            throw PolluxError.proxyStartFailed("The playback proxy does not have a bound port yet.")
        }
        return ProxyURLBuilder.proxyURL(port: localPort, targetURL: targetURL, host: advertisedHost)
    }

    private func removeConnection(_ identifier: UUID) {
        connections.removeValue(forKey: identifier)
    }
}

private struct ProxyRequest {
    let method: String
    let url: URL
    let headers: [String: String]

    static func parse(_ headerText: String) throws -> ProxyRequest {
        let lines = headerText
            .split(separator: "\r\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let requestLine = lines.first else {
            throw PolluxError.proxyStartFailed("The playback proxy received an empty request.")
        }

        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw PolluxError.proxyStartFailed("The playback proxy could not parse the request line.")
        }

        let method = String(components[0]).uppercased()
        let target = String(components[1])
        guard let url = safeURL(from: "http://127.0.0.1\(target)") else {
            throw PolluxError.proxyStartFailed("The playback proxy received an invalid local target.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else {
                continue
            }
            let name = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return ProxyRequest(method: method, url: url, headers: headers)
    }
}

private struct ProxyResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func encoded() -> Data {
        var response = Data()
        var headerLines = ["HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)"]
        for (name, value) in headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            headerLines.append("\(name): \(value)")
        }
        headerLines.append("Connection: close")
        headerLines.append("")
        headerLines.append("")

        response.append(Data(headerLines.joined(separator: "\r\n").utf8))
        response.append(body)
        return response
    }
}

private let hopByHopHeaders: Set<String> = [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
]

private func shouldForwardRequestHeader(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return !hopByHopHeaders.contains(lowered) && lowered != "accept-encoding" && lowered != "host"
}

private func shouldForwardResponseHeader(_ name: String, bodyRewritten: Bool) -> Bool {
    let lowered = name.lowercased()
    if hopByHopHeaders.contains(lowered) {
        return false
    }
    if !bodyRewritten {
        return true
    }
    return lowered != "content-length" && lowered != "content-encoding" && lowered != "accept-ranges"
}

private func buildErrorResponse(statusCode: Int, message: String) -> Data {
    ProxyResponse(
        statusCode: statusCode,
        headers: [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": "\(message.utf8.count)",
        ],
        body: Data(message.utf8)
    ).encoded()
}
