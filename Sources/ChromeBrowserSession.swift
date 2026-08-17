import AppKit
import Foundation

/// The capture + stealth setup every target needs, applied identically to the root page and to each
/// auto-attached child (out-of-process player iframe): network capture on, auto-attach extended inward,
/// the stealth script installed, and the UA/navigator overridden. Applying this to children as well as
/// the root closes a gap where an OOPIF player otherwise ran with an un-spoofed user agent. Every call
/// is best-effort — some child target types reject a subset, and on the root these either succeed (the
/// working case) or the extraction surfaces a clearer failure later.
struct TargetConfigurator: Sendable {
    let profile: BrowserProfile
    let mitigation: Bool

    func apply(on connection: CDPTargetConfigurable, sessionId: String?) async {
        await connection.enableDomain("Network", sessionId: sessionId)
        await connection.setAutoAttach(sessionId: sessionId)
        await connection.addStealthScript(
            mitigation ? profile.hardenedStealthScript : profile.stealthScript,
            sessionId: sessionId
        )
        await connection.setUserAgentOverride(
            userAgent: profile.userAgent,
            acceptLanguage: profile.acceptLanguage,
            platform: profile.platform,
            sessionId: sessionId
        )
    }
}

final class ChromiumProcessTracker: @unchecked Sendable {
    static let shared = ChromiumProcessTracker()

    private struct TrackedSession {
        let process: Process
        let userDataDirectory: URL
    }

    private var sessions: [UUID: TrackedSession] = [:]
    private let lock = NSLock()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func register(id: UUID, process: Process, userDataDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        sessions[id] = TrackedSession(process: process, userDataDirectory: userDataDirectory)
    }

    func unregister(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: id)
    }

    func terminateSession(id: UUID) {
        lock.lock()
        let tracked = sessions.removeValue(forKey: id)
        lock.unlock()

        if let tracked {
            if tracked.process.isRunning {
                tracked.process.terminate()
            }
            // Hard-kill the whole Chromium process tree (main + renderer/gpu/network helpers), which a
            // plain terminate() on the parent does not reliably reap, then delete the profile.
            Self.killProcessTree(userDataDirectory: tracked.userDataDirectory)
            try? FileManager.default.removeItem(at: tracked.userDataDirectory)
        }
    }

    @objc private func handleAppWillTerminate() {
        terminateAll()
    }

    func terminateAll() {
        lock.lock()
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        for tracked in allSessions {
            if tracked.process.isRunning {
                tracked.process.terminate()
            }
            Self.killProcessTree(userDataDirectory: tracked.userDataDirectory)
            try? FileManager.default.removeItem(at: tracked.userDataDirectory)
        }
    }

    /// Removes leftover extraction browsers from previous runs (e.g. after a crash or force-quit).
    /// Safe to call at launch — any `pollux-chrome-*` profile in the temp dir is stale because we have
    /// not started a session yet.
    func cleanupOrphans() {
        let tempDirectory = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for entry in entries where entry.lastPathComponent.hasPrefix("pollux-chrome-") {
            Self.killProcessTree(userDataDirectory: entry)
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Kills every process whose command line references this profile directory. The unique UUID in
    /// the path makes the match precise, so unrelated processes are never touched.
    private static func killProcessTree(userDataDirectory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", userDataDirectory.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // pkill unavailable or nothing matched — nothing more to do.
        }
    }
}

final class ChromeBrowserSession: BrowserSession, @unchecked Sendable {
    let id: UUID
    private static let largestIframeScript = """
    (function() {
      const iframes = document.querySelectorAll('iframe');
      let best = null, maxArea = 0;
      for (const f of iframes) {
        let src = f.src || f.getAttribute('data-src') || f.getAttribute('data-url') || f.getAttribute('src') || '';
        if (!src || src.startsWith('about:') || src.startsWith('javascript:')) continue;
        try { src = new URL(src, window.location.href).href; } catch(e) {}
        const r = f.getBoundingClientRect();
        const a = r.width * r.height;
        if (a > maxArea) { maxArea = a; best = src; }
      }
      if (best) return best;
      for (const f of iframes) {
        let src = f.src || f.getAttribute('data-src') || f.getAttribute('data-url') || f.getAttribute('src') || '';
        if (!src || src.startsWith('about:') || src.startsWith('javascript:')) continue;
        try { src = new URL(src, window.location.href).href; } catch(e) {}
        if (src.startsWith('http://') || src.startsWith('https://')) return src;
      }
      return null;
    })()
    """

    private static let turnstilePositionScript = """
    (function() {
        const f = document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"], .cf-turnstile iframe');
        if (!f) return null;
        const r = f.getBoundingClientRect();
        if (r.width < 10 || r.height < 10) return null;
        return {x: Math.round(r.x + Math.min(35, r.width / 2)), y: Math.round(r.y + r.height / 2)};
    })()
    """

    private static let turnstileGoneScript = """
    (function() {
        const resp = document.querySelector('[name="cf-turnstile-response"]');
        if (resp && resp.value && resp.value.length > 0) return true;
        const f = document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"], .cf-turnstile iframe');
        return f === null;
    })()
    """
    private static let startupTimeout: TimeInterval = 30
    private static let targetDiscoveryTimeout: TimeInterval = 15

    private let process: Process
    private let userDataDirectory: URL
    private let connection: CDPConnection
    private var closed = false
    private(set) var currentURL: URL?

    /// Anti-automation mitigation ("quiet CDP") is active for this session. Set once at launch.
    private let mitigation: Bool
    /// Execution context of the isolated world our probes run in when mitigation is active. Recreated
    /// after each navigation (navigation destroys the old world). `nil` means "use the default world",
    /// which is the behavior when mitigation is off or before the first world has been created.
    private var isolatedContextId: Int?

    private init(id: UUID, process: Process, userDataDirectory: URL, connection: CDPConnection, mitigation: Bool) {
        self.id = id
        self.process = process
        self.userDataDirectory = userDataDirectory
        self.connection = connection
        self.mitigation = mitigation
    }

    static func launch(
        profile: BrowserProfile,
        eventHandler: @escaping @Sendable (String, Data) async -> Void
    ) async throws -> ChromeBrowserSession {
        guard let executableURL = locateChromiumExecutable() else {
            throw PolluxError.chromiumMissing
        }

        let id = UUID()
        let userDataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pollux-chrome-\(id.uuidString)")
        try FileManager.default.createDirectory(at: userDataDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executableURL
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let diagnostics = ChromeLaunchDiagnostics(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        // Headful mode (opt-in): launch a real, visible window instead of headless so sites that
        // detect and block headless Chromium still render their player.
        let headful = UserDefaults.standard.bool(forKey: PolluxPreferences.headfulExtractionKey)
        // Anti-automation mitigation (opt-in "quiet CDP" path): active at the Standard level, off
        // otherwise. See `AntiAutomationLevel` for what the mitigation changes at launch and over CDP.
        let mitigation = AntiAutomationLevel.resolved() == .standard

        process.arguments = launchArguments(
            profile: profile,
            userDataDirectory: userDataDirectory,
            headful: headful,
            mitigation: mitigation
        )

        do {
            try process.run()
            ChromiumProcessTracker.shared.register(id: id, process: process, userDataDirectory: userDataDirectory)

            let port = try await waitForDebugPort(
                process: process,
                diagnostics: diagnostics,
                userDataDirectory: userDataDirectory,
                timeout: startupTimeout
            )
            let webSocketURL = try await waitForPageSocketURL(
                port: port,
                diagnostics: diagnostics,
                timeout: targetDiscoveryTimeout
            )
            let connection = CDPConnection(webSocketURL: webSocketURL)
            await connection.start()
            await connection.setEventHandler(eventHandler)

            let session = ChromeBrowserSession(
                id: id,
                process: process,
                userDataDirectory: userDataDirectory,
                connection: connection,
                mitigation: mitigation
            )
            try await session.configure(profile: profile)
            diagnostics.stop()
            return session
        } catch {
            diagnostics.stop()
            ChromiumProcessTracker.shared.terminateSession(id: id)
            if let polluxError = error as? PolluxError {
                throw polluxError
            }
            throw PolluxError.browserLaunchFailed(error.localizedDescription)
        }
    }

    /// Builds the Chromium command-line arguments. Extracted for unit testing so the mitigation and
    /// headful toggles can be verified without launching a real browser.
    static func launchArguments(
        profile: BrowserProfile,
        userDataDirectory: URL,
        headful: Bool,
        mitigation: Bool
    ) -> [String] {
        var arguments = [
            "--remote-debugging-port=0",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-dev-shm-usage",
            "--disable-blink-features=AutomationControlled",
            "--disable-infobars",
            "--use-mock-keychain",
            "--disable-background-timer-throttling",
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--autoplay-policy=no-user-gesture-required",
            "--incognito",
            "--disable-features=IsolateOrigins,site-per-process",
            "--window-size=\(profile.windowWidth),\(profile.windowHeight)",
            "--user-agent=\(profile.userAgent)",
        ]
        // `--disable-web-security` is itself a fingerprint (CORS/SharedArrayBuffer behavior differs from
        // a real browser). In the quiet-CDP path we drop it and instead fetch cross-origin playlists
        // from an isolated world granted universal access, which keeps capture working without the tell.
        if !mitigation {
            arguments.append("--disable-web-security")
        }
        if !headful {
            arguments.append("--headless=new")
        }
        arguments.append("about:blank")
        return arguments
    }

    func navigate(to url: URL, referrer: String? = nil, timeout: TimeInterval) async throws {
        var params: [String: Any] = ["url": url.absoluteString]
        if let referrer {
            params["referrer"] = referrer
        }
        currentURL = url
        // Navigation destroys any isolated world we created for the previous document; fall back to the
        // default world for the readyState probe until we can create a fresh one below.
        isolatedContextId = nil
        _ = try? await connection.call("Page.navigate", params: params, timeout: 10.0)
        do {
            try await waitForDocumentReady(timeout: min(timeout, 8.0))
        } catch {
            ExtractionLogger.log("Page ready state check notice: continuing pipeline to inspect player & network candidates.")
        }
        await refreshIsolatedWorld()
    }

    /// Creates a fresh isolated world in the main frame and remembers its execution context so that
    /// subsequent `Runtime.evaluate` calls run there instead of the page's main world. No-op unless
    /// anti-automation mitigation is active. The world is granted universal access so our cross-origin
    /// playlist fetches keep working without `--disable-web-security`.
    private func refreshIsolatedWorld() async {
        guard mitigation else { return }
        do {
            let tree = try await connection.callReturningDictionary("Page.getFrameTree", params: [:])
            guard let frameTree = tree["frameTree"] as? [String: Any],
                  let frame = frameTree["frame"] as? [String: Any],
                  let frameId = frame["id"] as? String else {
                isolatedContextId = nil
                return
            }
            let world = try await connection.callReturningDictionary("Page.createIsolatedWorld", params: [
                "frameId": frameId,
                "worldName": "pollux_probe",
                "grantUniveralAccess": true,
            ])
            isolatedContextId = world["executionContextId"] as? Int
        } catch {
            // If world creation fails we fall back to the default context; probing still works, just
            // without the isolation benefit.
            isolatedContextId = nil
        }
    }

    func click(x: Double, y: Double) async throws {
        _ = try await connection.call("Input.dispatchMouseEvent", params: [
            "type": "mouseMoved",
            "x": x,
            "y": y,
        ])
        _ = try await connection.call("Input.dispatchMouseEvent", params: [
            "type": "mousePressed",
            "x": x,
            "y": y,
            "button": "left",
            "clickCount": 1,
        ])
        _ = try await connection.call("Input.dispatchMouseEvent", params: [
            "type": "mouseReleased",
            "x": x,
            "y": y,
            "button": "left",
            "clickCount": 1,
        ])
    }

    func pollForIframeSource(timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let src = try? await evaluateString(ChromeBrowserSession.largestIframeScript),
               !src.isEmpty {
                return src
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    func clickPlayButtons() async {
        let script = """
        (() => {
          const selectors = ['button', '.play-btn', '.vjs-big-play-button', '#player', '[class*="play"]', '[id*="play"]', 'a.btn'];
          for (const s of selectors) {
            const el = document.querySelector(s);
            if (el && typeof el.click === 'function') {
              el.click();
              return true;
            }
          }
          return false;
        })()
        """
        _ = try? await evaluateBool(script)
    }

    func bypassTurnstile(solveTimeout: TimeInterval, retryTimeout: TimeInterval) async throws {
        let hasTurnstileScript = """
        (function() {
            return document.querySelector('.cf-turnstile, iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"]') !== null;
        })()
        """
        guard try await evaluateBool(hasTurnstileScript) else {
            return
        }

        ExtractionLogger.log("Detected Cloudflare Turnstile challenge. Attempting click solve...")
        _ = await attemptTurnstileSolve(timeout: solveTimeout)
    }

    func cookies() async throws -> [BrowserCookie] {
        let payload = try await connection.callReturningDictionary("Network.getCookies", params: [:])
        let cookies = payload["cookies"] as? [[String: Any]] ?? []
        return cookies.compactMap { cookie in
            guard
                let name = cookie["name"] as? String,
                let value = cookie["value"] as? String,
                let domain = cookie["domain"] as? String
            else {
                return nil
            }
            return BrowserCookie(name: name, value: value, domain: domain)
        }
    }

    /// Builds an in-page `fetch` wrapped in an `AbortController` timeout. `fetchOptions` and `readBody`
    /// are JS fragments spliced into the request and response-read steps; on any error the promise
    /// resolves to a `"ERROR: …"` sentinel string, since a CDP `Runtime.evaluate` can only return a
    /// string. `readBody` is responsible for calling `clearTimeout(timeoutId)` on its success path.
    private func browserFetchScript(
        url: URL,
        timeout: TimeInterval,
        timeoutMessage: String,
        fetchOptions: String,
        readBody: String
    ) -> String {
        let urlLiteral = quotedJavaScriptLiteral(url.absoluteString)
        return """
        (async () => {
          const controller = new AbortController();
          const timeoutId = setTimeout(() => controller.abort(new Error("\(timeoutMessage)")), \(Int(timeout * 1000)));
          try {
            const response = await fetch(\(urlLiteral), \(fetchOptions));
            \(readBody)
          } catch (error) {
            clearTimeout(timeoutId);
            return "ERROR: " + error.toString();
          }
        })()
        """
    }

    func fetchTextResource(at url: URL, timeout: TimeInterval) async throws -> String {
        let script = browserFetchScript(
            url: url,
            timeout: timeout,
            timeoutMessage: "Pollux playlist fetch timed out",
            fetchOptions: """
            {
                  signal: controller.signal,
                  cache: 'no-store',
                  headers: {
                    'Cache-Control': 'no-cache, no-store, must-revalidate',
                    'Pragma': 'no-cache'
                  }
                }
            """,
            readBody: """
            clearTimeout(timeoutId);
                return await response.text();
            """
        )
        return try await evaluateString(script) ?? ""
    }

    func fetchBinaryResource(at url: URL, timeout: TimeInterval) async throws -> Data {
        let script = browserFetchScript(
            url: url,
            timeout: timeout,
            timeoutMessage: "Pollux binary fetch timed out",
            fetchOptions: "{ signal: controller.signal }",
            readBody: """
            const blob = await response.blob();
                const dataURL = await new Promise((resolve, reject) => {
                  const reader = new FileReader();
                  reader.onloadend = () => resolve(reader.result || "");
                  reader.onerror = () => reject(reader.error || new Error("Failed to read fetched blob"));
                  reader.readAsDataURL(blob);
                });
                clearTimeout(timeoutId);
                return dataURL;
            """
        )
        let result = try await evaluateString(script) ?? ""
        if isBrowserFetchError(result) {
            throw PolluxError.unexpected(result)
        }
        guard let data = decodeBase64DataURL(result) else {
            throw PolluxError.unexpected("Browser binary fetch returned undecodable data.")
        }
        return data
    }

    /// Fetches a network response body the browser has already buffered, by CDP request id. Used to
    /// read stream URLs directly out of API/XHR JSON responses when an anti-bot player receives its
    /// stream config over the network but never issues the media request itself — so there is no
    /// `.m3u8` request to capture, only the JSON that describes it.
    /// Returns the decoded body text, or nil if the body is unavailable or binary.
    func fetchResponseBody(requestID: String) async -> String? {
        guard
            let dict = try? await connection.callReturningDictionary(
                "Network.getResponseBody",
                params: ["requestId": requestID],
                timeout: 5.0
            ),
            let body = dict["body"] as? String
        else {
            return nil
        }
        if dict["base64Encoded"] as? Bool == true {
            guard let data = Data(base64Encoded: body) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        return body
    }

    /// Silences CDP event delivery (network/console events). Extraction attaches a handler that logs
    /// and collects every network event; once we hand the live session to the playback proxy we must
    /// detach it, otherwise the running player's ongoing network traffic (plus our own proxy fetches)
    /// floods the collector and the @MainActor logger and hangs the app.
    func detachEventHandler() async {
        await connection.setEventHandler { _, _ in }
    }

    /// True when the document has finished loading but has no player, no iframe, and no visible text —
    /// the "blank/broken" state anti-bot pages serve to headless automation. Used to decide whether a
    /// fresh re-navigation is worth attempting.
    func pageLooksBlank() async -> Bool {
        let script = """
        (() => {
          if (document.readyState !== 'complete') return false;
          if (document.querySelector('video') || document.querySelector('iframe')) return false;
          const title = (document.title || '').trim();
          const bodyText = (document.body && document.body.innerText || '').trim();
          return title.length === 0 && bodyText.length === 0;
        })()
        """
        return (try? await evaluateBool(script)) ?? false
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true

        await connection.close()
        ChromiumProcessTracker.shared.terminateSession(id: id)
    }

    /// Capture a screenshot using CDP Page.captureScreenshot (compositor-level, no JS needed).
    func captureScreenshot() async throws -> String {
        let result = try await connection.callReturningDictionary("Page.captureScreenshot", params: [
            "format": "png",
        ], timeout: 5.0)
        guard let base64Data = result["data"] as? String,
              let imageData = Data(base64Encoded: base64Data) else {
            throw PolluxError.unexpected("Screenshot capture returned no data")
        }
        let screenshotDir = FileManager.default.temporaryDirectory.appendingPathComponent("pollux-screenshots")
        try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
        let filename = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        let filePath = screenshotDir.appendingPathComponent(filename)
        try imageData.write(to: filePath)
        return filePath.path
    }

    private func configure(profile: BrowserProfile) async throws {
        let configurator = TargetConfigurator(profile: profile, mitigation: mitigation)
        // Register child-target configuration BEFORE auto-attach can fire (it runs inside the shared
        // apply below). An out-of-process player iframe that attaches then gets the same setup as the
        // root — network capture, inward auto-attach, stealth, and UA override — rather than a subset.
        await connection.setChildConfigurator { [connection] sessionId in
            await configurator.apply(on: connection, sessionId: sessionId)
        }

        // Root-only domains and overrides the child targets don't need for pure network capture.
        _ = try await connection.call("Page.enable", params: [:])
        // `Runtime.enable` is the loudest CDP tell — it lets a page observe the DevTools console
        // serializer and conclude it is being automated. In the quiet-CDP path we never enable it;
        // `Runtime.evaluate` still works as a command without it, and we run probes in an isolated
        // world so they leave no trace in the page's main world. Cost: console-based m3u8 sniffing is
        // unavailable (Network-domain capture is the primary path anyway).
        if !mitigation {
            _ = try await connection.call("Runtime.enable", params: [:])
        }
        _ = try await connection.call("DOM.enable", params: [:])
        _ = try? await connection.call("Emulation.setAutomationOverride", params: ["enabled": false])
        _ = try? await connection.call("Emulation.setFocusEmulationEnabled", params: ["enabled": true])

        // Shared capture + stealth setup, applied identically to the root and every child target. This
        // enables Network (so the parent target's existing capture path is unchanged), extends
        // auto-attach to child targets, and installs the stealth script and UA override.
        await configurator.apply(on: connection, sessionId: nil)
    }

    func waitForDocumentReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let checkScript = """
        (() => {
          if (document.readyState === 'interactive' || document.readyState === 'complete') return true;
          if (document.body && (document.querySelector('iframe') || document.querySelector('video') || document.body.children.length > 0)) return true;
          return false;
        })()
        """
        while Date() < deadline {
            try Task.checkCancellation()
            if let isReady = try? await evaluateBool(checkScript), isReady {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let currentURL {
            throw PolluxError.navigationTimedOut(currentURL)
        }
        throw PolluxError.browserDidNotExposeDevTools
    }

    private func attemptTurnstileSolve(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var clicked = false

        while Date() < deadline {
            do {
                if try await evaluateBool(ChromeBrowserSession.turnstileGoneScript) {
                    return true
                }

                if !clicked, let point = try await evaluatePoint(ChromeBrowserSession.turnstilePositionScript) {
                    try await click(x: point.x, y: point.y)
                    clicked = true
                }
            } catch {
                return false
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return false
            }
        }

        return (try? await evaluateBool(ChromeBrowserSession.turnstileGoneScript)) ?? false
    }

    func evaluateString(_ script: String) async throws -> String? {
        let value = try await evaluate(script)
        return try cast(value, to: String.self)
    }

    private func evaluateBool(_ script: String) async throws -> Bool {
        let value = try await evaluate(script)
        return try cast(value, to: Bool.self) ?? false
    }

    private func evaluatePoint(_ script: String) async throws -> (x: Double, y: Double)? {
        let value = try await evaluate(script)
        guard let dictionary = try cast(value, to: [String: Double].self),
              let x = dictionary["x"],
              let y = dictionary["y"]
        else {
            return nil
        }
        return (x, y)
    }

    private func evaluate(_ script: String) async throws -> Any? {
        var params: [String: Any] = [
            "expression": script,
            "returnByValue": true,
            "awaitPromise": true,
        ]
        // When mitigation is active, run in the isolated world so nothing we evaluate is visible to the
        // page's main-world code. `contextId` is omitted (default world) when no isolated world exists.
        if let isolatedContextId {
            params["contextId"] = isolatedContextId
        }
        let result = try await connection.callReturningDictionary("Runtime.evaluate", params: params, timeout: 8.0)

        if let exception = result["exceptionDetails"] as? [String: Any],
           let text = exception["text"] as? String {
            throw PolluxError.unexpected(text)
        }

        guard let remoteObject = result["result"] as? [String: Any] else {
            return nil
        }
        if remoteObject["type"] as? String == "undefined" {
            return nil
        }
        if remoteObject["subtype"] as? String == "null" {
            return nil
        }
        return remoteObject["value"]
    }

    private func cast<T: Decodable>(_ value: Any?, to type: T.Type) throws -> T? {
        guard let value else {
            return nil
        }
        let wrapped = ["value": value]
        let data = try JSONSerialization.data(withJSONObject: wrapped, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(Wrapper<T>.self, from: data).value
    }
}

private struct DevToolsTarget: Decodable {
    let type: String
    let webSocketDebuggerURL: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}

private struct Wrapper<Value: Decodable>: Decodable {
    let value: Value
}

private final class ChromeLaunchDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    init(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, toStandardError: false)
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, toStandardError: true)
        }
    }

    func stop() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
    }

    func failureReason(fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let stderr = String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }

        let stdout = String(decoding: stdoutBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }

        return fallback
    }

    private func append(_ data: Data, toStandardError: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if toStandardError {
            stderrBuffer.append(data)
            trim(&stderrBuffer)
        } else {
            stdoutBuffer.append(data)
            trim(&stdoutBuffer)
        }
    }

    private func trim(_ buffer: inout Data) {
        let maxBytes = 4096
        if buffer.count > maxBytes {
            buffer.removeFirst(buffer.count - maxBytes)
        }
    }
}

private func waitForDebugPort(
    process: Process,
    diagnostics: ChromeLaunchDiagnostics,
    userDataDirectory: URL,
    timeout: TimeInterval
) async throws -> Int {
    let portFile = userDataDirectory.appendingPathComponent("DevToolsActivePort")
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if let contents = try? String(contentsOf: portFile, encoding: .utf8) {
            let lines = contents
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            if let portString = lines.first, let port = Int(portString) {
                return port
            }
        }

        if !process.isRunning {
            throw PolluxError.browserLaunchFailed(
                diagnostics.failureReason(fallback: "Chromium exited before Pollux could attach to its DevTools endpoint.")
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
    }

    throw PolluxError.browserLaunchFailed(
        diagnostics.failureReason(fallback: "Timed out waiting for Chromium's DevTools port.")
    )
}

private func waitForPageSocketURL(
    port: Int,
    diagnostics: ChromeLaunchDiagnostics,
    timeout: TimeInterval
) async throws -> URL {
    let deadline = Date().addingTimeInterval(timeout)
    let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list")!
    let createEndpoint = URL(string: "http://127.0.0.1:\(port)/json/new?about:blank")!
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var attemptedTargetCreation = false

    while Date() < deadline {
        do {
            let targets = try await fetchDevToolsTargets(from: endpoint, using: session)
            if let socketURL = targets.first(where: { $0.type == "page" })?.webSocketDebuggerURL {
                return socketURL
            }

            if !attemptedTargetCreation,
               let createdTarget = try await createDevToolsTarget(at: createEndpoint, using: session) {
                return createdTarget
            }
            attemptedTargetCreation = true
        } catch {
            // Keep retrying while Chromium is still warming up.
        }

        try await Task.sleep(nanoseconds: 100_000_000)
    }

    throw PolluxError.browserLaunchFailed(
        diagnostics.failureReason(fallback: "Chromium started, but it never exposed a page debugging target.")
    )
}

private func fetchDevToolsTargets(from endpoint: URL, using session: URLSession) async throws -> [DevToolsTarget] {
    let (data, _) = try await session.data(from: endpoint)
    return try JSONDecoder().decode([DevToolsTarget].self, from: data)
}

private func createDevToolsTarget(at endpoint: URL, using session: URLSession) async throws -> URL? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "PUT"
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
        return nil
    }
    return try JSONDecoder().decode(DevToolsTarget.self, from: data).webSocketDebuggerURL
}

