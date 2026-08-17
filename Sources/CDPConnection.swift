import Foundation

/// The minimal set of CDP commands `TargetConfigurator` needs to set a target up for capture. Abstracted
/// as a protocol so the configurator can be unit-tested against a spy without a live browser.
protocol CDPTargetConfigurable: Sendable {
    func enableDomain(_ domain: String, sessionId: String?) async
    func setAutoAttach(sessionId: String?) async
    func addStealthScript(_ source: String, sessionId: String?) async
    func setUserAgentOverride(userAgent: String, acceptLanguage: String, platform: String, sessionId: String?) async
}

actor CDPConnection: CDPTargetConfigurable {
    private let session: URLSession
    private let webSocket: URLSessionWebSocketTask
    private var pendingCalls: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextIdentifier = 1
    private var receiveTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (String, Data, String?) async -> Void)?
    private var isClosed = false
    /// Applies target setup to a freshly auto-attached child (OOPIF) session. Injected by the owning
    /// `ChromeBrowserSession` so children get the same configuration as the root. Nil until set.
    private var childConfigurator: (@Sendable (String) async -> Void)?

    init(webSocketURL: URL) {
        self.session = URLSession(configuration: .ephemeral)
        self.webSocket = session.webSocketTask(with: webSocketURL)
        // CDP replies carry response bodies inline (base64) — a `Runtime.evaluate` or `getResponseBody`
        // that returns a media segment is easily several MB. The default 1 MB WebSocket message limit
        // makes `receive()` throw "message too long" on those, which would otherwise kill the whole
        // connection. Raise it well above any single segment.
        self.webSocket.maximumMessageSize = 512 * 1024 * 1024
        self.webSocket.resume()
    }

    func setChildConfigurator(_ configure: @escaping @Sendable (String) async -> Void) {
        childConfigurator = configure
    }

    // MARK: - CDPTargetConfigurable

    /// Enables a CDP domain (e.g. `Network`). Best-effort: some child target types reject a subset.
    func enableDomain(_ domain: String, sessionId: String? = nil) async {
        _ = try? await call("\(domain).enable", params: [:], sessionId: sessionId)
    }

    /// Turns on flat-mode auto-attach so nested child targets are caught too. Best-effort.
    func setAutoAttach(sessionId: String? = nil) async {
        _ = try? await call("Target.setAutoAttach", params: [
            "autoAttach": true,
            "waitForDebuggerOnStart": false,
            "flatten": true,
        ], sessionId: sessionId)
    }

    /// Installs a script to run on every new document (the stealth patches). Best-effort.
    func addStealthScript(_ source: String, sessionId: String? = nil) async {
        _ = try? await call("Page.addScriptToEvaluateOnNewDocument", params: ["source": source], sessionId: sessionId)
    }

    /// Overrides the user agent / navigator fields the target reports. Best-effort.
    func setUserAgentOverride(userAgent: String, acceptLanguage: String, platform: String, sessionId: String? = nil) async {
        _ = try? await call("Emulation.setUserAgentOverride", params: [
            "userAgent": userAgent,
            "acceptLanguage": acceptLanguage,
            "platform": platform,
        ], sessionId: sessionId)
    }

    func start() {
        guard receiveTask == nil else {
            return
        }
        receiveTask = Task {
            await self.receiveLoop()
        }
    }

    func setEventHandler(_ eventHandler: @escaping @Sendable (String, Data, String?) async -> Void) {
        self.eventHandler = eventHandler
    }

    func call(_ method: String, params: [String: Any], timeout: TimeInterval = 10.0, sessionId: String? = nil) async throws -> Data {
        guard !isClosed else {
            throw PolluxError.browserDidNotExposeDevTools
        }

        let identifier = nextIdentifier
        nextIdentifier += 1

        var payload: [String: Any] = [
            "id": identifier,
            "method": method,
            "params": params,
        ]
        // Flat-mode auto-attach: a command addressed to an auto-attached child target (e.g. an
        // out-of-process player iframe) carries the child's sessionId at the envelope top level.
        if let sessionId {
            payload["sessionId"] = sessionId
        }
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

    /// Convenience over `call` for the common case where the command's result is a JSON object:
    /// decodes the reply in one step, removing the `jsonDictionary(from: try await call(...))` dance
    /// repeated across the session's CDP call sites.
    func callReturningDictionary(
        _ method: String,
        params: [String: Any],
        timeout: TimeInterval = 10.0,
        sessionId: String? = nil
    ) async throws -> [String: Any] {
        try jsonDictionary(from: await call(method, params: params, timeout: timeout, sessionId: sessionId))
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
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await webSocket.receive()
            } catch {
                // A `receive()` failure means the socket itself is gone — fatal.
                if !isClosed {
                    failAllPending(error: error)
                }
                return
            }
            do {
                switch message {
                case .data(let data):
                    try await handleMessage(data)
                case .string(let string):
                    try await handleMessage(Data(string.utf8))
                @unknown default:
                    break
                }
            } catch {
                // A single malformed/oversized message must not kill the connection — skip and keep
                // reading. (Fatal socket errors are handled by the receive() catch above.)
                continue
            }
        }
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

        // Flat-mode auto-attach: when a child target attaches (an out-of-process player iframe whose
        // media requests never reach the top target), enable Network on its session so its events flow
        // here alongside the parent's. Dispatched to a detached task — enabling the child requires a CDP
        // call whose reply is delivered by this same receive loop, so awaiting it inline would deadlock.
        if method == "Target.attachedToTarget",
           let params = object["params"] as? [String: Any],
           let sessionId = params["sessionId"] as? String {
            let targetType = (params["targetInfo"] as? [String: Any])?["type"] as? String
            if targetType == "iframe" || targetType == "page" {
                Task { await self.bootstrapChildSession(sessionId) }
            }
        }

        let paramsObject = object["params"] ?? [:]
        let paramsData = try JSONSerialization.data(withJSONObject: paramsObject, options: [.fragmentsAllowed])
        if let eventHandler {
            // Flat-mode auto-attach delivers child-target (OOPIF) events on the same socket, tagged with
            // the child's sessionId at the envelope top level. Pass it through so a handler can call
            // `getResponseBody` against the right session.
            await eventHandler(method, paramsData, object["sessionId"] as? String)
        }
    }

    /// Configures a freshly auto-attached child target (an out-of-process player iframe) with the same
    /// setup as the root — network capture, inward auto-attach, stealth, and UA override — via the
    /// injected configurator. Best-effort and purely additive: the parent target's capture is unaffected.
    /// Falls back to the minimal capture setup if no configurator was registered.
    private func bootstrapChildSession(_ sessionId: String) async {
        if let childConfigurator {
            await childConfigurator(sessionId)
        } else {
            await enableDomain("Network", sessionId: sessionId)
            await setAutoAttach(sessionId: sessionId)
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

func jsonDictionary(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
        return [:]
    }
    return object
}

func quotedJavaScriptLiteral(_ string: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [string])
    let encoded = String(decoding: data, as: UTF8.self)
    return encoded.dropFirst().dropLast().description
}

func headerMap(from rawHeaders: Any?) -> [String: String] {
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

