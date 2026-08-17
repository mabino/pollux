import Foundation

/// What a completed interaction step tells the driver to do next.
enum InteractionStepOutcome {
    /// Continue to the next step in this pass.
    case proceed
    /// Abandon the rest of this pass and start a fresh one (the pipeline's old `continue`), used after
    /// a blank-page reload so the freshly loaded document is re-inspected from the top.
    case restartLoop
}

/// One named interaction the pipeline tries against the page in order to coax the player into issuing
/// its media request (probe the DOM, recover from a blank page, solve Turnstile, enter the player
/// iframe, click the viewport, click HTML5 play controls). Steps never test for a captured stream
/// themselves — the driver does that once between steps — which is what removes the six near-identical
/// `if collector.hasHits() { … }` blocks the pipeline used to carry.
struct InteractionStep {
    let name: String
    /// Message logged if a media candidate is present immediately after this step runs.
    let captureLog: String
    let run: (inout InteractionContext) async -> InteractionStepOutcome
}

/// Mutable state threaded through a pass of the interaction pipeline. The blank-page counters and
/// `pipelineStart` persist across passes; `jsMainThreadBlocked` is reset at the top of each pass.
struct InteractionContext {
    let session: ChromeBrowserSession
    let profile: BrowserProfile
    let deadline: Date
    let sourcePageURL: URL
    let settings: ExtractionSettings
    let pipelineStart: Date
    var jsMainThreadBlocked = false
    var consecutiveBlankProbes = 0
    var lastReload: Date
    var reloadCount = 0
}

extension InteractionStep {
    /// The ordered pipeline. Order is load-bearing: probe first (so later steps know whether the JS
    /// thread is usable), recover a blank page before interacting with it, solve Turnstile before
    /// clicking, defer entering the player iframe until in-place clicks have had a chance, and only
    /// then click the viewport and HTML5 controls.
    static let pipeline: [InteractionStep] = [
        .probePageState,
        .blankPageRecovery,
        .turnstileBypass,
        .iframeNavigation,
        .viewportClick,
        .playButtons,
    ]

    /// Probe page state via the DOM (which does not need the JS main thread to be responsive). If the
    /// evaluate times out, the JS main thread is blocked — record that so JS-dependent steps skip, and
    /// fall back to a compositor-level screenshot.
    static let probePageState = InteractionStep(
        name: "probePageState",
        captureLog: "Media candidate captured while inspecting page state."
    ) { ctx in
        let domSummaryScript = """
        (() => {
          const iframes = Array.from(document.querySelectorAll('iframe')).map(i => i.src || i.getAttribute('data-src') || 'no-src');
          const videos = document.querySelectorAll('video').length;
          const title = document.title;
          const bodyText = (document.body && document.body.innerText || '').substring(0, 200);
          return 'readyState=' + document.readyState + ', title=' + title + ', iframes=' + iframes.length + ' [' + iframes.slice(0, 3).join(', ') + '], videos=' + videos + ', body=' + bodyText;
        })()
        """
        do {
            if let summary = try await ctx.session.evaluateString(domSummaryScript) {
                ExtractionLogger.log("DOM State: \(summary)")
            }
        } catch {
            ctx.jsMainThreadBlocked = true
            ExtractionLogger.log("JS main thread blocked (eval timeout). Capturing screenshot...")
            if let screenshotPath = try? await ctx.session.captureScreenshot() {
                ExtractionLogger.log("Screenshot saved: \(screenshotPath)")
            }
        }
        return .proceed
    }

    /// If the document loaded but rendered no player/content, the site likely served the anti-bot blank
    /// page. After two consecutive blank probes (and past a reload cooldown), re-navigate for a fresh
    /// load and restart the pass so the new document is inspected from the top.
    static let blankPageRecovery = InteractionStep(
        name: "blankPageRecovery",
        captureLog: "Media candidate captured after blank-page check."
    ) { ctx in
        if !ctx.jsMainThreadBlocked, await ctx.session.pageLooksBlank() {
            ctx.consecutiveBlankProbes += 1
            let cooldownElapsed = Date().timeIntervalSince(ctx.lastReload) > ctx.settings.blankPageReloadCooldown
            if ctx.consecutiveBlankProbes >= 2, cooldownElapsed, ctx.deadline.timeIntervalSinceNow > ctx.settings.blankPageReloadCooldown {
                ctx.reloadCount += 1
                let attempt = ctx.reloadCount
                ExtractionLogger.log("Page looks blank (likely anti-bot). Re-navigating for a fresh load (attempt \(attempt))...")
                try? await ctx.session.navigate(to: ctx.sourcePageURL, timeout: min(ctx.settings.browserTimeout, 8))
                ctx.lastReload = Date()
                ctx.consecutiveBlankProbes = 0
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return .restartLoop
            }
        } else {
            ctx.consecutiveBlankProbes = 0
        }
        return .proceed
    }

    /// Solve a Cloudflare Turnstile challenge if present. Skipped when the JS thread is blocked.
    static let turnstileBypass = InteractionStep(
        name: "turnstileBypass",
        captureLog: "Media candidate captured after Turnstile check."
    ) { ctx in
        if !ctx.jsMainThreadBlocked {
            try? await ctx.session.bypassTurnstile(
                solveTimeout: ctx.settings.turnstileSolveTimeout,
                retryTimeout: ctx.settings.turnstileRetryTimeout
            )
        }
        return .proceed
    }

    /// Fallback: navigate the top tab into the largest player iframe. Deferred until in-place clicks
    /// have had a grace window, because many embeds build the real player as a nested iframe from tokens
    /// the parent injects — navigating the top tab straight into the embed discards that context.
    static let iframeNavigation = InteractionStep(
        name: "iframeNavigation",
        captureLog: "Media candidate captured inside iframe."
    ) { ctx in
        guard !ctx.jsMainThreadBlocked,
              Date().timeIntervalSince(ctx.pipelineStart) >= ctx.settings.iframeNavigationDelay else {
            return .proceed
        }
        if let iframeSource = await ctx.session.pollForIframeSource(timeout: 2.0),
           let iframeURL = safeURL(from: iframeSource) {
            if iframeURL != ctx.session.currentURL {
                ExtractionLogger.log("No stream captured in place; navigating into player iframe: \(iframeURL.absoluteString)")
                try? await ctx.session.navigate(to: iframeURL, referrer: ctx.session.currentURL?.absoluteString, timeout: 5)
            }
        }
        return .proceed
    }

    /// Click the viewport center via the CDP Input domain (works even when the JS main thread is blocked).
    static let viewportClick = InteractionStep(
        name: "viewportClick",
        captureLog: "Media candidate captured after viewport click."
    ) { ctx in
        let centerX = ctx.profile.centerX
        let centerY = ctx.profile.centerY
        ExtractionLogger.log("Clicking player viewport center (x: \(centerX), y: \(centerY))...")
        try? await ctx.session.click(x: centerX, y: centerY)
        return .proceed
    }

    /// Query and click common HTML5 play controls. Skipped when the JS thread is blocked (uses evaluate).
    static let playButtons = InteractionStep(
        name: "playButtons",
        captureLog: "Media candidate captured after clicking play controls."
    ) { ctx in
        if !ctx.jsMainThreadBlocked {
            ExtractionLogger.log("Querying and clicking HTML5 play controls...")
            await ctx.session.clickPlayButtons()
        }
        return .proceed
    }
}
