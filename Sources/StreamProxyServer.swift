import Foundation
import Network

actor StreamProxyServer {
    private let stream: ExtractedStream
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.mabino.pollux.proxy")
    private let session: URLSession

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var started = false

    init(stream: ExtractedStream) throws {
        self.stream = stream

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
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
        let browserSession = stream.session
        Task {
            await browserSession?.close()
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

        if isTargetURLPlaylist {
            if let cachedPlaylist = stream.cachedPlaylists[targetURL.absoluteString], shouldServeCachedPlaylist(cachedPlaylist) {
                let filtered = filterExcludedVariantsFromMasterPlaylist(
                    Data(cachedPlaylist.utf8),
                    playlistURL: targetURL,
                    excludedVariantURLs: stream.excludedVariantURLs
                )
                let rewritten = try rewritePlaylistData(filtered, playlistURL: targetURL) {
                    ProxyURLBuilder.proxyURL(port: localPort, targetURL: $0)
                }
                let proxyResponse = ProxyResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": StreamKind.hls.mimeType,
                        "Content-Length": "\(rewritten.count)",
                    ],
                    body: request.method == "HEAD" ? Data() : rewritten
                )
                return proxyResponse.encoded()
            }

            if let browserSession = stream.session {
                if let fetchedText = try? await browserSession.fetchTextResource(at: targetURL, timeout: 6),
                   !fetchedText.isEmpty,
                   !fetchedText.hasPrefix("ERROR:")
                {
                    let filtered = filterExcludedVariantsFromMasterPlaylist(
                        Data(fetchedText.utf8),
                        playlistURL: targetURL,
                        excludedVariantURLs: stream.excludedVariantURLs
                    )
                    let rewritten = try rewritePlaylistData(filtered, playlistURL: targetURL) {
                        ProxyURLBuilder.proxyURL(port: localPort, targetURL: $0)
                    }
                    let proxyResponse = ProxyResponse(
                        statusCode: 200,
                        headers: [
                            "Content-Type": StreamKind.hls.mimeType,
                            "Content-Length": "\(rewritten.count)",
                        ],
                        body: request.method == "HEAD" ? Data() : rewritten
                    )
                    return proxyResponse.encoded()
                }
            }

            if let cachedPlaylist = stream.cachedPlaylists[targetURL.absoluteString], !cachedPlaylist.isEmpty {
                let filtered = filterExcludedVariantsFromMasterPlaylist(
                    Data(cachedPlaylist.utf8),
                    playlistURL: targetURL,
                    excludedVariantURLs: stream.excludedVariantURLs
                )
                let rewritten = try rewritePlaylistData(filtered, playlistURL: targetURL) {
                    ProxyURLBuilder.proxyURL(port: localPort, targetURL: $0)
                }
                let proxyResponse = ProxyResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": StreamKind.hls.mimeType,
                        "Content-Length": "\(rewritten.count)",
                    ],
                    body: request.method == "HEAD" ? Data() : rewritten
                )
                return proxyResponse.encoded()
            }
        }

        var upstreamRequest = URLRequest(url: targetURL)
        upstreamRequest.httpMethod = request.method
        applyCapturedHeaders(to: &upstreamRequest, downstreamHeaders: request.headers)

        print("[Proxy] Requesting upstream method=\(request.method) url=\(targetURL) headers=\(upstreamRequest.allHTTPHeaderFields ?? [:])")
        let (responseBody, urlResponse) = try await session.data(for: upstreamRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw PolluxError.proxyStartFailed("The upstream stream server returned an invalid response.")
        }
        print("[Proxy] Upstream status=\(httpResponse.statusCode) url=\(targetURL)")

        let upstreamHeaders = filteredHeaders(from: httpResponse, bodyRewritten: false)
        let responseContentType = upstreamHeaders["Content-Type"]?.lowercased() ?? ""
        let isPlaylist =
            responseContentType.contains("mpegurl") ||
            targetURL.pathExtension.lowercased() == "m3u8" ||
            request.url.path.lowercased().hasSuffix(".m3u8")

        if isPlaylist {
            let rewritten = try rewritePlaylistData(responseBody, playlistURL: targetURL) {
                ProxyURLBuilder.proxyURL(port: localPort, targetURL: $0)
            }
            var headers = filteredHeaders(from: httpResponse, bodyRewritten: true)
            headers["Content-Type"] = StreamKind.hls.mimeType
            headers["Content-Length"] = "\(rewritten.count)"
            let proxyResponse = ProxyResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: request.method == "HEAD" ? Data() : rewritten
            )
            return proxyResponse.encoded()
        }

        if let browserSession = stream.session,
           let browserFetchedBody = try? await browserSession.fetchBinaryResource(at: targetURL, timeout: 6)
        {
            let rewrittenBody = stripPNGHeaderIfNeeded(browserFetchedBody)
            let proxyResponse = ProxyResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": proxyContentType(for: targetURL),
                    "Content-Length": "\(rewrittenBody.count)",
                ],
                body: request.method == "HEAD" ? Data() : rewrittenBody
            )
            return proxyResponse.encoded()
        }

        let rewrittenBody = stripPNGHeaderIfNeeded(responseBody)
        var headers = filteredHeaders(from: httpResponse, bodyRewritten: rewrittenBody.count != responseBody.count)
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/octet-stream"
        }
        headers["Content-Length"] = "\(rewrittenBody.count)"

        let proxyResponse = ProxyResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: request.method == "HEAD" ? Data() : rewrittenBody
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
        return ProxyURLBuilder.proxyURL(port: localPort, targetURL: targetURL)
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
        guard let url = URL(string: "http://127.0.0.1\(target)") else {
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
