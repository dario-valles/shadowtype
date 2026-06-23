// CompletionCoordinator — the hot loop (P2). Orchestrates:
//   keystroke -> debounce (FR-KC-5) -> prefix-before-caret (FR-CE-9) -> streamed
//   inference -> ghost overlay -> Tab/word accept -> Injector.
// Threading (PRD §7.6): onKeystroke()/acceptWord()/acceptLine() are invoked on the
// MAIN queue (InputMonitor hands events off on main). Inference runs on a dedicated
// serial queue; overlay/UI touches hop back to main. Completion requests are a
// bounded newest-wins channel: there is at most one in-flight generation and one
// pending request; a newer keystroke supersedes both (FR-CE-4 cancel + FR §7.6).
import Cocoa
import NaturalLanguage

// Ghost-text opacity. Shadowtype is free and unlimited — every suggestion shows at full opacity and
// nothing is ever suppressed for a word cap. Kept as a thin shim so call sites stay readable.
enum WordCap {
    /// Ghost-text opacity multiplier — always full (1). Never nil; suggestions are never capped.
    static func opacity() -> CGFloat? { 1 }
}

final class CompletionCoordinator {
    // Confidence-gating thresholds (see ConfidenceGate). Conservative defaults tuned to drop obvious
    // word-salad without eating good suggestions; override at runtime via env for live tuning.
    static let firstTokenMinProb: Double =
        envDouble("SHADOWTYPE_GATE_FIRST") ?? 0.10
    static let meanMinProb: Double =
        envDouble("SHADOWTYPE_GATE_MEAN") ?? 0.08

    private static func envDouble(_ key: String) -> Double? {
        ProcessInfo.processInfo.environment[key].flatMap(Double.init)
    }

    private let engine: InferenceEngineProtocol
    private let overlay: OverlayRenderer
    private let context: EditContextTracker

    // INTEGRATOR-NOTE: the coordinator needs the Injector + WordMeter to satisfy
    // acceptWord()/acceptLine() (FR §M4) and to know which apps are disabled.
    // The init signature is frozen (engine/overlay/context only), so these are
    // injected via setters that the AppDelegate can call right after construction
    // without changing the constructor. If you prefer constructor injection, widen
    // the init — but that touches the frozen signature, so setters are used here.
    var injector: Injector?
    var wordMeter: WordMeter?
    // Per-app / per-domain enable rules (FR-PA-1/2). Shared single instance owned by AppDelegate so
    // the menu "Pause for this app" toggle and the coordinator's gate read the same state. nil == on
    // everywhere (e.g. before wiring). Replaces the old in-memory disabledBundleIds set.
    var appRules: AppRules?
    // Per-app behavior tri-states (mid-line, autocorrect, Disable Tab, collect-inputs). Defaults to the
    // shared store; never nil so the hot-path resolve() calls don't need an optional dance. Tests can
    // swap in a hermetic instance.
    var appSettings = AppSettingsStore.shared
    // Built-in `:shortcode:` -> emoji (FR-EM-1, Free). When the prefix is an active shortcode the
    // hot path shows the best emoji match and Tab inserts it (0 words). nil disables emoji mode.
    var emoji: EmojiCompletion?
    // Shortcuts → "Emoji shortcode" toggle (Free, default ON). When off, the `:shortcode` ghost is
    // never offered and the prefix falls through to the normal LLM/typo path. AppDelegate.syncToggles
    // mirrors the @AppStorage value here on launch + every change.
    var emojiEnabled: Bool = true
    // FR-CE-6 (Free half): suppress a suggestion when the last typed word looks like a mid-typing typo.
    var typoGuard: TypoGuard?
    // General → "Hold back suggestions on likely typos" (Free, default ON). When off, a likely-typo
    // trailing word no longer suppresses the suggestion (the model just continues from it); the paid
    // autocorrect OFFER path is independent and still fires when licensed + enabled. Mirrored by
    // AppDelegate.syncToggles.
    var holdBackOnTypos: Bool = true
    // FR-AC-1 (paid): the upgrade to TypoGuard. When the last word looks like a typo AND the user is
    // licensed AND autocorrectEnabled, OFFER a concrete fix (correction ghost) instead of merely
    // suppressing. Pure value type; default-constructed so it is safe even before wiring. nil disables.
    var autocorrect: Autocorrect? = Autocorrect()
    // FR-AC-1 user toggle (paid). Mirrors the OCR/emoji toggle flow: default OFF, persisted in
    // UserDefaults ("GW.autocorrectEnabled"), kept in sync by AppDelegate's didChange observer.
    var autocorrectEnabled: Bool = false
    // FR-CTX-3 (paid): on-device encrypted writing-style personalization. Injected (defaults to the
    // shared instance) so M-loop tests can pass a hermetic StyleProfile(storeURL:secret:). Read+written
    // only when isLicensed && styleProfileEnabled.
    var styleProfile: StyleProfile? = StyleProfile.shared
    var styleProfileEnabled: Bool = true
    // FR-CTX-3 Personalization → "strength" (paid, 0...3). Scales the style-hint char budget prepended
    // to the prompt: 0 = off (no hint, even when learning stays on), 1/2/3 = progressively larger bias.
    // Mirrored by AppDelegate.syncToggles; read on focus-in when the hint snapshot is rebuilt.
    var personalizationStrength: Int = 3
    // FR-CTX-2 (paid): clipboard-aware context. Synchronous pasteboard read prepended as leading
    // context. Read only when isLicensed && clipboardContextEnabled (default OFF).
    var clipboard: ClipboardContextProvider? = ClipboardContextProvider()
    var clipboardContextEnabled: Bool = false
    // FR-PA-3 (paid): custom global + per-app instructions. Shared store; read only when isLicensed.
    var instructionStore: InstructionStore? = InstructionStore.shared
    // FR-CTX-1 on-screen OCR context (Free). Only consulted when `useScreenOCR` is true (default OFF);
    // the recognized text is prepended as extra LEADING context — the prompt stays forward-from-caret.
    var screenContext: ScreenContextProvider?
    var useScreenOCR: Bool = false
    // Settings → "Show Tab hint on suggestions" (default ON). Draws a faint "⇥ Tab" keycap after the
    // ghost so new users learn the accept key; auto-hidden once they've accepted `tabHintThreshold`
    // suggestions (the count persists, so the cue fades for good). Mirrored by AppDelegate.syncToggles.
    var showTabHint: Bool = true
    private let tabHintThreshold = 8
    private var tabHintAcceptCount: Int {
        get { UserDefaults.standard.integer(forKey: "shadowtype.tabHintAcceptCount") }
        set { UserDefaults.standard.set(newValue, forKey: "shadowtype.tabHintAcceptCount") }
    }
    // Show the keycap only while the toggle is on AND the user hasn't yet learned the gesture.
    private var tabHintActive: Bool { showTabHint && tabHintAcceptCount < tabHintThreshold }
    var isEnabled: Bool = true
    // Settings → "Show Smart Compose coexistence tip" (default ON). When ON, a successful render on
    // mail.google.com runs the cheap Smart Compose overlap check; when OFF the whole code path
    // (including the AX value read) is skipped entirely. Mirrored by AppDelegate.syncToggles.
    var smartComposeNudgeEnabled: Bool = true

    // Max chars of OCR context to prepend when useScreenOCR is on (FR-CTX-1). The OCR text is stable
    // for ~1s (throttled capture), so KV-reuse keeps this leading context warm across keystrokes —
    // only a refresh re-prefills it — which is why a larger budget stays cheap on the hot path.
    private let ocrContextChars = 1024
    // Max chars of AX page-text context (the thread-aware reply backend). Larger than the OCR budget:
    // a web page holds the conversation ABOVE the compose box, and clamp() keeps the TAIL (nearest the
    // caret = the opened message + quoted thread), dropping the inbox/sidebar at the page top.
    private let pageContextChars = 4000
    // Last OCR text resolved off the hot path (FR-CTX-1). Read synchronously when building the prompt
    // so the latency-critical generate() never awaits; refreshed by a background Task on each fire.
    private var ocrCache: String?
    private let ocrLock = NSLock()

    // Per-focus OCR capture lifecycle (main-thread only). `.pending` = the capture for this focus is in
    // flight and we have NO context yet, so fire() holds back the first (context-blind) guess until it
    // lands; `.ready` = the capture completed (even if it found no prose) so prefix-only is allowed.
    private enum OCRCaptureState { case idle, pending, ready }
    private var ocrCaptureState: OCRCaptureState = .idle

    // Bound for the context-driven re-fire (main-thread only). refreshOCRContextIfEnabled re-fires
    // generation when the captured on-screen context changes, so a context-blind first guess gets
    // upgraded to a context-aware one. Without a bound, a dynamic screen (a clock tick, a "typing…"
    // indicator, scrolling) makes every ~1s capture read as "changed" and re-fire forever — the ghost
    // visibly cycles through a new suggestion each second during a single pause. A COUNT cap (not a
    // prefix key) is what bounds it: an earlier per-prefix latch keyed off a freshly re-read
    // currentPrefix(), which drifts/flickers nil in Electron/web hosts (Slack), so the key never
    // matched and the re-fire was never blocked. The count is immune to that and to the OCR-feedback
    // case (a capture that includes the rendered ghost). cancel() (every keystroke / focus change /
    // force-activate) resets it so each new typing action gets exactly one fresh context upgrade.
    private var contextRefireCount = 0
    private static let maxContextRefires = 1

    // Dominant language of the on-screen context fed into the CURRENT generation's prompt (nil when
    // there is no confident single-language context). Set in assembledPrompt, read in renderSuggestion
    // to suppress a completion that drifts to a different language than the surrounding conversation
    // (user choice: match the conversation, else hide). Reset in cancel().
    private var generationContextLang: NLLanguage?

    // Tier 2a: true while the current generation is a mid-word HEAL — the engine regenerated the typed
    // word from a clean boundary and already stripped the reproduced stem, so the ghost text is final.
    // renderSuggestion then skips the prefix-relative transforms (reconcile leading space / glue guard /
    // prefix-dup / language drift), which assume a fresh continuation and would mangle the healed tail
    // ("at" → " at"). Set per generation in startGeneration. See MidWordHealing / RequiredPrefix.
    private var generationIsHealed = false

    // True while the current generation is a TERMINAL shell-command completion (the buffer was a plain
    // shell prompt). renderSuggestion then skips ALL prose transforms (markup strip, list-marker strip,
    // glue/leading-space reconcile, language-drift guards) — every one corrupts shell syntax (backticks =
    // command substitution, `*` = glob, leading `-` = flag) — and instead runs only a newline truncation
    // plus the destructive-command guard. Set per generation in startGeneration / the history fast path.
    private var generationShellMode = false

    // Cached writing-style hint (FR-CTX-3). Like the OCR cache, this is refreshed ONLY on focus-in (the
    // cold path), NOT per keystroke: the profile only changes on a Tab-accept, and recomputing it inside
    // assembledPrompt would (a) re-run two O(N log N) sorts over the 400-entry n-gram table on every
    // keystroke and (b) SHIFT the prompt's leading tokens after each accept, busting the FR-CE-5 warm KV
    // cache on the next keystroke. Snapshotting it per focus-in keeps the leading block stable during a
    // typing burst (warm) and moves the sort off the hot path.
    private var styleHintCache: String?
    private let styleHintLock = NSLock()

    // Shadowtype is free and fully unlocked: every feature path is always on. This constant keeps the
    // ~12 historical `if isLicensed` gates readable while always taking the unlocked branch.
    let isLicensed = true

    // True while a selection-rewrite is generating or its preview HUD is up (set by AppDelegate). The
    // keystroke hot path stays quiet during it so the ghost loop doesn't fight the rewrite UI.
    var rewriteActive = false

    // No daily cap: the product is unlimited, so the menu meter shows no cap.
    var dailyCap: Int? { nil }

    // Suggestions are never suppressed for a cap.
    var isSuppressedByCap: Bool { false }

    // INTEGRATOR-NOTE: this fires when a suggestion's visibility changes. Wire it to
    // TabSwallowTap.setSuggestionVisible(_:) so Tab is only swallowed while a ghost is
    // shown (the tap reads this atomically on its own thread — see TabSwallowTap).
    var onSuggestionVisibleChanged: ((Bool) -> Void)?

    // Snapshot of caretAtLineEnd pushed at every ghost show + accept-advance so the
    // TabSwallowTap can gate Right Arrow accepts without a sync AX call from the tap thread.
    // False is pushed on every clear so a stale-true can't outlive the ghost.
    var onCaretAtLineEndChanged: ((Bool) -> Void)?

    // MARK: - Tunables (FR-KC-5 / FR-CE-7)
    // Settings-adjustable (General → "Suggestion trigger delay"). AppDelegate.syncToggles mirrors the
    // @AppStorage value here on launch + every change; clamped to the slider's 40–400 ms range there.
    var debounce: TimeInterval = 0.120                // ~120 ms idle before triggering — the adaptive FLOOR
    private let deadline: TimeInterval = 0.400        // drop silently if no first token by here

    // Adaptive typing-pause trigger (research: waiting for a *natural* pause raises acceptance and
    // near-eliminates sub-0.3 s "blind rejections" vs a fixed delay — arXiv 2511.18842). The fixed
    // `debounce` above is the FLOOR; the real wait scales with the user's own recent typing cadence ×
    // `pauseMultiplier`, clamped to [debounce, adaptivePauseCeiling]. A fast typist gets a snappy short
    // wait; a slow/hunt-peck typist gets a longer one so we only fire on a genuine pause, not mid-burst.
    // AppDelegate mirrors `pauseMultiplier` from the Aggressiveness setting; both default to "balanced".
    var adaptivePause = true
    var pauseMultiplier: Double = 2.3
    // Hard cap on the wait. In practice this only binds for slow/hunt-peck typists (large median IKI),
    // for whom a longer wait is exactly right — a fast typist's median×multiplier stays well under it.
    // Set above a deliberate "thinking pause" (~0.6–1.0 s) so we still fire on genuine pauses.
    private let adaptivePauseCeiling: TimeInterval = 1.0
    // Monotonic timestamp of the previous keystroke and a small ring of recent inter-keystroke intervals
    // (session-break gaps excluded) used to estimate the user's natural cadence. Main-thread only.
    private var lastKeystrokeUptime: TimeInterval = 0
    private var recentIKIs: [TimeInterval] = []
    private let maxIKISamples = 16
    // Set when a suggestion actually fires (i.e. the user paused). The next keystroke's interval then
    // spans that pause + read time, not typing cadence, so we skip sampling it (FR-KC-5 quality).
    private var skipNextIKISample = false
    // ~24 tokens buys a useful multi-word phrase now that the engine's stop policy is widened
    // to allow multi-word/multi-clause continuations (FR-CE-3). The engine still stops early at
    // its boundary; this is just the ceiling.
    // INTEGRATOR-NOTE: contract with the engine agent — engine.generate(prompt:maxTokens:onToken:)
    // stays as-is; the engine gains a *settable* stop policy (e.g. engine.stopPolicy = .phrase).
    // If you expose that setter, set it once at wiring time in AppDelegate; the coordinator does
    // not configure it here to keep that single owner.
    // INTEGRATOR-OWNED: settable so AppDelegate can drive it from CompletionLength.current(isLicensed:)
    // at launch and on every license / length-preference change (FR-CE-3). Default 24 keeps the Free
    // product unchanged until wired. The coordinator never reads CompletionLength itself — AppDelegate
    // is the single owner of that tunable wiring (see lines above).
    var maxTokens = 24

    // Token ceiling for a terminal shell-command completion — one command line is short, and a hard cap
    // bounds runaway generation if the model misses the newline stop.
    static let shellMaxTokens = 48

    // Paid leading-context char budgets (FR-CTX-2/3, FR-PA-3). Kept small and consistent with the OCR
    // budget so KV-reuse stays warm and truncation order is predictable. Each block is only prepended
    // when its feature is licensed + toggled on.
    private let clipboardContextChars = 512

    // Minimum useful context before we bother the model: at least this many non-space chars in the
    // prefix, OR at least one fully-completed word. Below this, suggestions are noise (FR-KC-5).
    private let minPrefixChars = 2

    // MARK: - Queues
    // Dedicated serial inference queue (PRD §7.6: inference off the main thread). Internal (not
    // private) since M1 so `LocalAPIServer` can dispatch API/MCP requests onto the same queue,
    // serializing them with ghost-text decodes (one llama_decode at a time). The seqID parameter
    // on `engine.generate` keeps the KV caches isolated even though decode is serialized.
    let inferenceQueue = DispatchQueue(label: "com.shadowtype.inference", qos: .userInitiated)

    // MARK: - State (all mutated on main unless noted)
    private var debounceWork: DispatchWorkItem?

    // Newest-wins generation token. Bumped on every cancel/new-request. The inference
    // closure compares its captured id to this; a mismatch means it has been superseded
    // and returns false to cooperatively stop the engine (FR-CE-4). Read on the inference
    // queue, written on main — guarded by `genLock`.
    private let genLock = NSLock()
    private var generation: Int = 0

    // The prompt-prefix that produced the currently-displayed (or in-flight) suggestion.
    // Used both to detect strict-extension (KV reuse opportunity, FR-CE-5) and to size
    // word/line acceptance against the live suggestion text.
    private var activePrefix: String = ""
    // Memo for applyGlueGuard: renderSuggestion runs on every streamed token snapshot, but for a fixed
    // prefix the trailing word and the suggestion's leading glue run are stable — so the language detect
    // + two spell lookups should run once per generation, not per token. Keyed on (prefix, glue run,
    // first 24 chars of the suggestion) — the suggestion slice disambiguates two different suggestions
    // that share a prefix + leading-letter run (e.g. both space-leading).
    private var glueGuardMemoKey: String?
    private var glueGuardMemoResult: String?
    private var suggestionText: String = ""
    // When the live suggestion is an emoji match (FR-EM-1), accept inserts exactly this emoji and
    // counts 0 words. The query length is how much of the typed `:shortcode` to replace on accept.
    private var emojiSuggestion: String?
    private var emojiQueryLength: Int = 0
    // FR-AC-1 (paid): the autocorrect "correction" ghost. When set, the live ghost is a one-edit fix for
    // the mistyped trailing token (`correctionRun`); accept atomically replaces that run with
    // `correctionSuggestion` (Injector.replaceBeforeCaret), counting 0 words. Never the LLM path.
    private var correctionSuggestion: String?
    private var correctionRun: String?
    private var suggestionVisible: Bool = false {
        didSet {
            guard suggestionVisible != oldValue else { return }
            onSuggestionVisibleChanged?(suggestionVisible)
            // Snapshot caret-at-end only on the rising edge — a per-token push would burn an AX
            // call per frame. Falling edge always pushes false (no AX) so a stale-true can't
            // outlive the ghost. Accept-advance paths re-push explicitly after the inject.
            if suggestionVisible {
                onCaretAtLineEndChanged?(context.caretAtLineEnd())
                startFontWatch()
            } else {
                onCaretAtLineEndChanged?(false)
                stopFontWatch()
            }
        }
    }
    // A host font-size/typeface change (e.g. TextEdit's toolbar stepper) emits no AX value- or
    // focus-changed notification, so the visible ghost would keep its stale size until the next
    // keystroke or app switch. Such a change is driven by a click (toolbar/menu/stepper); while a
    // gate-tracked completion ghost is up, watch left-mouse-up and re-read the host font, re-rendering
    // in place only if it actually changed. Keyboard size shortcuts (⌘+/⌘-) already route through
    // onKeystroke()→cancel(), so they regenerate with the new font on their own — no watch needed.
    private var fontWatchMonitor: Any?
    // Acceptance-rate bookkeeping (local Statistics only): true once the currently-shown completion has
    // had ≥1 word accepted, so word-by-word Tab accepts of one suggestion count as a single acceptance.
    // Reset to false when a fresh completion is shown (the rising edge in renderSuggestion).
    private var currentSuggestionAccepted = false

    // Floors the ghost font's caret height to the per-focus-session minimum so a single AX poll that
    // returns the full field-height fallback can't render a giant ghost (#1).
    private var ghostFontStabilizer = GhostFontSizeStabilizer()
    // Geometry of the last overlay we actually drew; gates whether a render tick repositions the panel
    // or holds it (#2). nil when nothing is shown.
    private var lastRenderedOverlay: OverlayStabilityGate.Rendered?
    // Surviving record of the last text actually sent to overlay.show(), independent of the stability
    // gate's snapshot (which is reset on clearSuggestion()/untrackOverlay()). Catches the dominant
    // "shows twice" pattern: a context re-fire (or any path that briefly clears) regenerates the
    // IDENTICAL text and would re-emit it — this drops the redundant emission within a short window.
    // Reset only on user-initiated clears (so an Esc + retype still shows the suggestion fresh).
    private var lastEmitState: OverlayEmitDedup.State?
    // Whether a ghost is ACTUALLY on screen right now (true after overlay.show(), false after
    // overlay.hide()). Gates the emit-dedup: a dropped re-show is only correct while the ghost is still
    // up — otherwise the dedup record (kept across a re-fire clear) would suppress a real show and leave
    // suggestionVisible=true with nothing visible (phantom Tab-accept).
    private var overlayPresented = false
    // True while a context-driven re-fire's generation is streaming. Holds the visible ghost as long
    // as the new token stream is a prefix of the currently-shown suggestion (the model regenerating
    // the same text), avoiding the otherwise-visible "Lorem ipsum" → "L" → "Lo" … rebuild flicker.
    // Cleared on stream divergence, generation done, or any explicit clear/cancel.
    private var inContextRefire: Bool = false
    // Stream-token render coalescer. Local-model bursts can fire many main-queue renderSuggestion
    // calls per frame; coalescing subsequent tokens to ≤1 render per ~33 ms (≈1 frame at 30 fps)
    // kills per-token re-anchor jitter while still respecting "first token shows immediately".
    private var pendingStreamSnapshot: String?
    private var pendingStreamWork: DispatchWorkItem?
    private let streamCoalesceWindow: TimeInterval = 0.033
    // RTL-ness of the current generation's prefix, computed ONCE when the prefix is set (the caret text
    // is fixed for a generation) instead of re-scanning it on every streamed token (#14).
    private var generationRTL = false
    // Debounces a transient "field briefly reports no editable context" flicker on the same focus
    // session so the ghost doesn't tear down and rebuild (#3).
    private var capabilityGate = FocusCapabilityFlickerGate()

    init(engine: InferenceEngineProtocol, overlay: OverlayRenderer, context: EditContextTracker) {
        self.engine = engine
        self.overlay = overlay
        self.context = context
    }

    // MARK: - Hot path (FR-KC-5)

    // Called on main for every observed keystroke. Cancels any in-flight/pending work
    // immediately (newest-wins, FR-CE-4) and re-arms the debounce timer. The actual
    // trigger decision (boundary / secure / disabled) is deferred to fire() so it reads
    // fresh AX state after the keystroke has settled.
    // `uptime` is the keystroke's press time, sampled on the tap thread (InputEvent.uptime), so cadence
    // isn't skewed by the main-queue hand-off latency.
    func onKeystroke(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        cancel()
        guard isEnabled, engine.isLoaded, !rewriteActive else { return }

        let work = DispatchWorkItem { [weak self] in self?.fire() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + adaptiveDelay(at: uptime), execute: work)
    }

    // The idle wait before firing, adapted to the user's typing cadence (FR-KC-5; research 2511.18842).
    // Records the inter-keystroke interval since the last keystroke, then returns the confirmed-pause
    // threshold: `debounce` (floor) until we have enough samples, else median-cadence × pauseMultiplier
    // clamped to [debounce, adaptivePauseCeiling]. Main-thread only (called from onKeystroke). `now` is
    // the tap-thread press time, not the main-queue arrival time.
    private func adaptiveDelay(at now: TimeInterval) -> TimeInterval {
        defer { lastKeystrokeUptime = now }
        let floor = debounce
        guard adaptivePause else { return floor }
        if lastKeystrokeUptime > 0, !skipNextIKISample {
            let dt = now - lastKeystrokeUptime
            // Keep only true intra-burst intervals so the median tracks burst speed, not pauses: a gap
            // ≥1 s is itself a deliberate pause/session break (the thing we fire ON), not typing cadence.
            if dt > 0, dt < 1.0 {
                recentIKIs.append(dt)
                if recentIKIs.count > maxIKISamples {
                    recentIKIs.removeFirst(recentIKIs.count - maxIKISamples)
                }
            }
        }
        // The skip applies to exactly one interval — the one spanning the pause that just fired.
        skipNextIKISample = false
        // Until we've seen a few intervals, behave exactly like the old fixed debounce.
        guard recentIKIs.count >= 3 else { return floor }
        let target = Self.median(recentIKIs) * pauseMultiplier
        return min(adaptivePauseCeiling, max(floor, target))
    }

    private static func median(_ xs: [TimeInterval]) -> TimeInterval {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    // Force-activate (global hotkey / menu "Force suggestions here"): trigger a suggestion for the
    // focused field NOW, bypassing the auto-idle gate for this one shot. Skips the debounce (the user
    // explicitly asked); every other safety gate — secure field, per-app/domain disable, boundary,
    // min-context, daily cap — still applies.
    func forceActivate() {
        guard isEnabled, engine.isLoaded, !rewriteActive else { return }   // don't supersede a live rewrite
        cancel()                  // clear any pending/in-flight work + ghost first
        fire(forced: true)        // bypass the auto-idle gate for this one explicit trigger
    }

    // Cancel in-flight generation + pending debounce, hide the ghost (FR-CE-4).
    func cancel() {
        debounceWork?.cancel()
        debounceWork = nil
        bumpGeneration()           // supersede any in-flight closure
        engine.requestCancel()     // cooperative stop between chunks/tokens
        contextRefireCount = 0     // a new keystroke/focus/force re-arms the one context-upgrade re-fire
        generationContextLang = nil
        clearSuggestion()
    }

    // MARK: - Local API runner (M1 — Pro)

    // Per-request cancel signal handed to HTTP handlers so they can bail the underlying decode
    // when the client disconnects, or when an SSE writer fails mid-stream. Distinct from the
    // engine's shared `cancelRequested` (which a ghost keystroke can flip): the engine reads BOTH
    // — engine-level for unload/reload + ghost interrupts, and the onToken closure reads this token
    // for client-disconnect. v1 limitation: a ghost keystroke during an in-flight API request
    // CAN still interrupt the API decode (shared cancel flag); the HTTP client sees a short
    // response and retries. M2+ may add per-seq cancel flags if this becomes a real issue.
    final class APIRequestCancelToken {
        private let lock = NSLock()
        private var _cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            _cancelled = true
        }
    }

    enum LocalAPIError: Error {
        case modelNotLoaded    // engine has no resident model (idle-unloaded or first-run)
        case decodeFailed(Error)
    }

    // Run an API/MCP raw completion on the shared engine via seq 1. Serializes through
    // `inferenceQueue` so ghost text (seq 0) and the API path can't decode simultaneously, but each
    // owns its own KV slot inside the same context so an API prompt won't evict the ghost prefix.
    //
    // `onPiece` is called on the inference queue per decoded chunk; return false (or set the
    // cancel token) to bail. `onComplete` is called on the inference queue after the engine call
    // returns; HTTP handlers should hop to their writer queue inside it as needed.
    //
    // Always available — Shadowtype is free, so the Local API serves without any license gate.
    func runRawCompletion(prompt: String,
                          params: SamplingParams,
                          maxTokens: Int,
                          cancelToken: APIRequestCancelToken,
                          onPiece: @escaping (String) -> Bool,
                          onComplete: @escaping (Result<Void, LocalAPIError>) -> Void) {
        inferenceQueue.async { [weak self] in
            // Review #5: route handlers block on a DispatchSemaphore waiting for onComplete to
            // fire — if we early-return without invoking it (coordinator deallocated during
            // teardown), the HTTP worker hangs forever and leaks the socket. Always call
            // onComplete on EVERY exit path so the route writes a response and closes.
            guard let self else {
                onComplete(.failure(.modelNotLoaded))
                return
            }
            guard self.engine.isLoaded else { onComplete(.failure(.modelNotLoaded)); return }
            do {
                try self.engine.generate(prompt: prompt,
                                         maxTokens: maxTokens,
                                         seqID: 1,
                                         params: params,
                                         requiredPrefix: nil,
                                         onToken: { piece in
                                             if cancelToken.isCancelled { return false }
                                             return onPiece(piece)
                                         },
                                         onSample: nil)
                onComplete(.success(()))
            } catch {
                onComplete(.failure(.decodeFailed(error)))
            }
        }
    }

    // Engine's read-only chat-template metadata, used by the /v1/chat/completions route to decide
    // whether the model supports chat rendering (returns 400 + steers to /v1/completions if nil).
    var modelChatTemplate: String? { engine.modelChatTemplate }

    // GGUF architecture + whether chat rendering actually works (template recognized or fallback
    // available). /v1/models advertises `supports_chat` from `modelSupportsChat`, and the chat route
    // passes `modelArchitecture` to ChatTemplate.apply so the fallback renderer can engage.
    var modelArchitecture: String? { engine.modelArchitecture }
    var modelSupportsChat: Bool { engine.modelSupportsChat }

    // M5 FIM: surface engine capability so /v1/completions can gate the OpenAI `suffix` field.
    var modelSupportsFIM: Bool { engine.supportsFIM }

    // MARK: - Selection rewrite (local, paid)

    // Run the on-device model to rewrite `selection` per `action`, delivering the cleaned result on the
    // main queue (nil = unavailable / empty output). Paid feature, gated on isLicensed like instructions/
    // style/clipboard. Reuses the single engine on the serial inferenceQueue with the same newest-wins
    // bumpGeneration discipline as ghost generation: it cancels any running decode so its prompt gets the
    // queue promptly, and is itself superseded (returns nothing) if the user triggers again. Unlike the
    // ghost path this is a ONE-SHOT instruction-style few-shot prompt (RewriteAction), so the KV cache
    // resets to a cold prefill — acceptable for an explicit, occasional action.
    func rewrite(selection: String, action: RewriteAction, completion: @escaping (String?) -> Void) {
        guard isLicensed, engine.isLoaded, !selection.isEmpty else { completion(nil); return }
        let tone = instructionStore?.effectiveInstruction(bundleId: context.frontmostBundleId)
        // Steer the base model to the SELECTION's language. The exemplar is English; without an explicit
        // marker the model mirrors it and emits English regardless of what the user selected. Confidence
        // threshold matches languageDrifts (0.50) — selections are user-curated, lower noise than OCR.
        let lang = Self.dominantLanguage(selection, minConfidence: 0.50).flatMap(Self.englishLanguageName)
        let prompt = RewriteAction.prompt(for: action, selection: selection, userTone: tone, language: lang)
        let budget = RewriteAction.maxTokens(forSelection: selection)
        // A rewrite is a FULL multi-sentence transformation, not an inline ghost. The ghost stop
        // policy (maxWords cap + first-sentence/newline stop) would truncate it — a multi-sentence
        // selection came back as just the first ~5 words ("Have you installed the beta"). Stream raw
        // tokens governed only by maxTokens + our few-shot stop strings: keep the ghost's low-temp,
        // repeat-penalized sampling (good for faithful rewrites) but turn OFF the engine stop policy.
        var params = SamplingParams.ghostDefaults
        params.useEngineStopPolicy = false
        params.stopStrings = ["\nText:", "\nText (", "\nRewritten:"]
        let myGen = bumpGeneration()
        engine.requestCancel()     // stop a running ghost decode so the serial queue frees up promptly
        Diag.log("rewrite: action=\(action.rawValue) selLen=\(selection.count) budget=\(budget) lang=\(lang ?? "auto")")
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            var acc = ""
            do {
                try self.engine.generate(prompt: prompt, maxTokens: budget, seqID: 0, params: params,
                                         requiredPrefix: nil, onToken: { piece in
                    guard self.isCurrent(myGen) else { return false }
                    acc += piece
                    // Stop as soon as the base model rolls into a fresh few-shot block (the runaway tail).
                    // `\nText (` also catches the language-tagged marker (`Text (in Spanish):`).
                    return !acc.contains("\nText:") && !acc.contains("\nText (")
                }, onSample: nil)
            } catch {
                Diag.log("rewrite: ERROR \(error)")
            }
            let cleaned = RewriteAction.cleanOutput(acc, selectionWasMultiline: selection.contains("\n"))
            DispatchQueue.main.async {
                guard self.isCurrent(myGen) else { return }
                Diag.logContent("rewrite: done out=\"\(cleaned.prefix(60))\"")
                completion(cleaned.isEmpty ? nil : cleaned)
            }
        }
    }

    // MARK: - Trigger (runs on main after debounce)

    // `forced` is true only on the force-activate path (hotkey / menu); it bypasses the auto-idle gate
    // for that one explicit trigger. The debounced keystroke path always passes false.
    private func fire(forced: Bool = false) {
        debounceWork = nil
        // We only get here because the debounce elapsed with no keystroke — i.e. the user paused. The
        // next keystroke's interval therefore spans that pause + read time, not cadence: don't sample it.
        skipNextIKISample = true
        guard isEnabled, engine.isLoaded else { Diag.log("fire: skip (enabled=\(isEnabled) loaded=\(engine.isLoaded))"); return }

        // FR-KC-4 / disabled-app+domain gate: never suggest in a secure field or a suppressed
        // app/domain (FR-PA-1/2). AppRules default is on everywhere; nil rules == on everywhere.
        if context.isSecureField() { Diag.log("fire: skip secureField"); clearSuggestion(); return }
        // IME composition guard: while marked (preedit) text is live — CJK composition — never fire,
        // and clear any visible ghost (it overlaps the candidate window and an accept would splice into
        // the composition buffer). Best-effort single AX read; hosts that don't expose AXMarkedTextRange
        // return false and behave exactly as before (see EditContextTracker.hasMarkedText).
        if context.hasMarkedText() { Diag.log("fire: skip markedText (IME composing)"); clearSuggestion(); return }
        if let appRules, !appRules.isEnabled(bundleId: context.frontmostBundleId,
                                             domain: context.frontmostDomainHost()) {
            Diag.log("fire: skip disabledApp/domain \(context.frontmostBundleId ?? "?")"); clearSuggestion(); return
        }

        // Read the terminal's visible buffer ONCE per keystroke and reuse it for both the idle gate and
        // the shell-mode decision below (an AX value read is an IPC round-trip; doing it twice per
        // keystroke is wasteful). nil for non-terminals, so ordinary apps pay nothing.
        let shellBuffer = ActivationPolicy.isTerminal(bundleId: context.frontmostBundleId)
            ? context.focusedElementText() : nil

        // Auto-idle contexts (terminals at a normal shell prompt, code-editor surfaces): stay quiet by
        // default so we don't fight shell/editor completion. The force-activate path bypasses this.
        if !forced, shouldStayIdle(terminalText: shellBuffer) {
            Diag.log("fire: skip idleContext \(context.frontmostBundleId ?? "?")"); clearSuggestion(); return
        }

        // Structured-input fields (browser address/omnibox, find bar, search boxes) are not prose —
        // a ghost there offers URL/query garbage (the "aelo.com in the address bar" case). Skip unless
        // force-activated.
        if !forced, context.focusedFieldIsNonProse() {
            Diag.log("fire: skip nonProseField \(context.frontmostBundleId ?? "?")"); clearSuggestion(); return
        }

        // FR-CE-9: prefix-before-caret ONLY. nil => no editable focus. Read once and run it through the
        // capability-flicker gate (#3): a single nil read on the SAME focus session is usually a
        // transient republish (Catalyst fields drop their value mid-redraw), so hold the current ghost
        // instead of tearing it down. A genuine focus change (different session) or a sustained miss
        // still propagates to the teardown below.
        // On web-mail hosts, the caret may sit BELOW the quoted-reply block (Gmail's "Show trimmed
        // content" reveal); the raw prefix then ends with "On <date>, X wrote:" + ">"-lines and the
        // ghost would just continue the quoted prose. Strip the trailing quoted block so the prompt
        // sees the user's actual new prose (often empty → bail cleanly).
        let originalPrefix = context.currentPrefix()
        let rawPrefix = Self.prefixAfterEmailQuoteStrip(
            originalPrefix, host: context.frontmostDomainHost())
        let hasContext = !((rawPrefix ?? "").isEmpty)
        if case let .suppress(misses) = capabilityGate.evaluate(hasContext: hasContext,
                                                                focusSeq: context.focusChangeSequence) {
            Diag.log("fire: hold (capability flicker, miss \(misses))")
            return
        }
        guard let prefix = rawPrefix, !prefix.isEmpty else {
            let cause = (originalPrefix?.isEmpty == false) ? "quoted-strip consumed all" : "AX gave no text-before-caret"
            Diag.log("fire: skip prefix=nil/empty (app=\(context.frontmostBundleId ?? "?")) — \(cause)")
            let host = context.frontmostDomainHost()
            // Web editors like Google Docs render to a canvas macOS AX can't read; rather than fail
            // silently, surface a one-time nudge (gated + de-duped by AXNudgeStore) pointing the user
            // at that app's own screen-reader setting.
            // Cheap session pre-gate BEFORE the AX host read: once every hostile host is prompted or
            // dismissed there's nothing to show, so skip the per-keystroke documentURL walk entirely.
            if AXNudgeStore.shared.mayStillPrompt(), let h = host,
               AXNudge.isHostile(host: h), AXNudgeStore.shared.notePrefixMiss(host: h) {
                NotificationCenter.default.post(name: .shadowtypeShowAXNudge, object: nil,
                                                userInfo: ["host": h])
            }
            // Web-mail self-heal: a nil prefix on a Gmail/Outlook host most often means Chrome built
            // its AX tree without the compose iframe primed (cold tab, slow SPA). Re-apply the
            // AXManualAccessibility nudge so the NEXT keystroke can read the freshly-built tree
            // instead of waiting for the user to type several words before the ghost appears.
            if ActivationPolicy.isWebMailHost(host) {
                context.rewakeBrowserAXIfPossible()
            }
            clearSuggestion(); return
        }

        // Terminal shell-command mode decision (buffer already read above). Drives gate relaxation
        // (commands fire mid-token), the history fast path, and the command-shaped prompt/sampling in
        // startGeneration. nil buffer / non-terminal → shellMode false, every prose path below unchanged.
        let shellMode = shellBuffer.map { ActivationPolicy.terminalMode($0) == .shellCommand } ?? false

        // Per-app "mid-line completions" (Cotypist): only suggest at end-of-line by default —
        // suppress when there's text after the caret on the same line. Mid-line ghosts overlap real
        // post-caret text and read as broken UX; users can opt in per-app to restore the old behavior.
        if !appSettings.resolve(\.midLine, forBundleId: context.frontmostBundleId, globalDefault: false),
           !context.caretAtLineEnd() {
            Diag.log("fire: skip midLineOff \(context.frontmostBundleId ?? "?")")
            clearSuggestion(); return
        }

        // FR-EM-1: emoji shortcode mode. When the prefix ends in an active `:shortcode`, show the best
        // emoji match as the ghost and let Tab insert it (0 words). This pre-empts the LLM path.
        if let emoji, emojiEnabled, emoji.isTrigger(prefix: prefix),
           let best = emoji.matches(prefix: prefix, limit: 1).first,
           let query = emoji.currentQuery(prefix: prefix) {
            Diag.logContent("fire: emoji match :\(best.shortcode): -> \(best.emoji)")
            // +1 for the leading `:`; this is the run we replace when the user accepts.
            showEmoji(best.emoji, queryLength: query.count + 1)
            return
        }

        // FR-CE-6 (Free half) + FR-AC-1 (paid upgrade): if the last typed word looks like a mid-typing
        // typo, the Free behavior holds back the suggestion entirely (Cotypist). The PAID upgrade, when
        // isLicensed && autocorrectEnabled, instead OFFERS a concrete one-edit fix as a special
        // "correction" ghost (Tab deletes the mistyped run + injects the fix, 0 words). Gating order
        // matters: only offer when BOTH licensed and toggled on; otherwise fall through to Free suppress.
        let lastWord = Self.lastWord(of: prefix)
        if let typoGuard, typoGuard.looksLikeTypo(lastWord: lastWord) {
            if isLicensed,
               appSettings.resolve(\.autocorrect, forBundleId: context.frontmostBundleId, globalDefault: autocorrectEnabled),
               let autocorrect, let fix = autocorrect.correction(for: lastWord) {
                Diag.log("fire: autocorrect offer")
                Diag.logContent("fire: autocorrect \"\(lastWord)\" -> \"\(fix)\"")
                showCorrection(fix, run: lastWord)
                return
            }
            // General → "Hold back on likely typos" (default ON): suppress the suggestion. When the user
            // turns it off, fall through and let the model continue from the (possibly mistyped) word.
            if holdBackOnTypos {
                Diag.log("fire: skip typo")
                Diag.logContent("fire: skip typo lastWord=\"\(lastWord)\"")
                clearSuggestion(); return
            }
        }

        // FR-KC-5: only fire at a word/whitespace boundary where a continuation is
        // meaningful — i.e. just after finishing a word (last char is alnum) or right
        // after a separating space. Mid-token keystrokes are too noisy to suggest on.
        // Shell mode bypasses this: shells autosuggest on every keystroke (paths/flags have no word
        // boundaries — `cd /et`, `git -`), matching fish/zsh-autosuggestions behaviour.
        guard shellMode || isMeaningfulBoundary(prefix) else {
            Diag.log("fire: skip notBoundary")
            Diag.logContent("fire: skip notBoundary prefixTail=\"\(String(prefix.suffix(12)))\"")
            clearSuggestion(); return
        }

        // FR-KC-5: require a minimum useful context (>= minPrefixChars non-space chars or >= 1
        // completed word) before triggering — avoids firing on a lone letter or stray punctuation.
        guard hasUsefulContext(prefix) else {
            Diag.log("fire: skip thinContext")
            Diag.logContent("fire: skip thinContext prefixTail=\"\(String(prefix.suffix(12)))\"")
            clearSuggestion(); return
        }

        // Don't fire in the gap right after a finished sentence (terminal punctuation + a space): a
        // continuation there is usually an unwanted new clause, not a completion of the user's text.
        // Shell mode bypasses this — `.`/`!`/`?` are ordinary in paths and command args, not sentence ends.
        guard shellMode || !Self.endsCompleteStatement(prefix) else {
            Diag.log("fire: skip completeStatement")
            clearSuggestion(); return
        }

        // Shell-command mode: the terminal buffer IS the context, so the OCR path is irrelevant. Try the
        // zero-hallucination history fast path (a prior visible command that extends the typed stem) and,
        // on a hit, render it verbatim without ever touching the model. Secret-bearing matches are dropped
        // (never surface a token/password as a ghost), and the danger guard still applies.
        if shellMode, let buffer = shellBuffer {
            let current = Self.shellCurrentLine(prefix)
            if let remainder = ShellHistory.prefixMatch(currentLine: current, buffer: buffer),
               !remainder.isEmpty {
                let full = current + remainder
                if Self.redactingSecrets(full) == full, !ShellCommandGuard.isDangerous(fullCommand: full) {
                    Diag.log("fire: shell history match -> render (no model)")
                    showShellHistory(prefix: prefix, remainder: remainder)
                    return
                }
            }
        }

        // FR-CTX-1: keep the OCR context fresh for the CURRENT viewport. Re-capturing on this pause (not
        // just focus-in) reflects scrolling and late captures; the provider's ≤1/s throttle + the
        // storeOCRCache change-guard keep KV warm when the visible text hasn't changed.
        if useScreenOCR, !shellMode {
            refreshOCRContextIfEnabled()
            // Don't paint a context-blind guess while this focus's first capture is still in flight — its
            // completion re-fires with real context. Only suppress when we have NOTHING yet (.pending, no
            // cache); a completed-but-empty capture (.ready) falls through to prefix-only.
            ocrLock.lock(); let haveOCR = ocrCache != nil; ocrLock.unlock()
            if !haveOCR, ocrCaptureState == .pending {
                Diag.log("fire: defer (OCR capture pending, no context yet)")
                clearSuggestion(); return
            }
        }

        Diag.log("fire: START gen len=\(prefix.count)\(shellMode ? " [shell]" : "")")
        Diag.logContent("fire: START gen prefixTail=\"\(String(prefix.suffix(24)))\"")
        startGeneration(prefix: prefix, shellMode: shellMode, terminalBuffer: shellBuffer)
    }

    // Render a history-derived shell completion verbatim, bypassing the model. Mirrors how
    // startGeneration seeds the per-generation flags so renderSuggestion takes the shell-mode branch
    // (Tab then injects `suggestionText`, exactly like a model completion).
    private func showShellHistory(prefix: String, remainder: String) {
        bumpGeneration()                       // supersede any in-flight model run
        activePrefix = prefix
        generationRTL = false
        generationIsHealed = false
        generationContextLang = nil
        generationShellMode = true
        renderSuggestion(remainder)
    }

    // Ghost opacity — Shadowtype is free and unlimited, so suggestions always show at full opacity.
    private func capOpacity() -> CGFloat? { WordCap.opacity() }

    // Trigger when the prefix ends on a word char (completing a word) or a single
    // trailing space (starting the next word). Avoid firing inside leading/trailing
    // whitespace runs or on pure punctuation noise.
    private func isMeaningfulBoundary(_ prefix: String) -> Bool {
        guard let last = prefix.last else { return false }
        if last.isLetter || last.isNumber { return true }
        if last == " " {
            // exactly one trailing space, preceded by a word char
            let trimmed = prefix.dropLast()
            if let prev = trimmed.last, !prev.isWhitespace { return true }
        }
        return false
    }

    // Enough signal to be worth a generation: at least `minPrefixChars` non-space chars, OR a
    // completed word already exists in the prefix (a trailing space after a word counts).
    private func hasUsefulContext(_ prefix: String) -> Bool {
        let nonSpace = prefix.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        if nonSpace >= minPrefixChars { return true }
        // A single short token followed by a space still gives the model a word to continue from.
        return prefix.contains(" ") && nonSpace >= 1
    }

    // Whether the focused field is an auto-idle context Shadowtype stays quiet in by default
    // (terminals at a normal shell prompt, code-editor surfaces). Gathers the AX signals only for the
    // managed app families so ordinary apps pay nothing; ActivationPolicy makes the pure decision.
    private func shouldStayIdle(terminalText: String?) -> Bool {
        let bundleId = context.frontmostBundleId
        guard ActivationPolicy.isManaged(bundleId: bundleId) else { return false }
        let heights = ActivationPolicy.isEditor(bundleId: bundleId) ? context.focusedFieldAndWindowHeights() : nil
        let shellOptIn = ActivationPolicy.isTerminal(bundleId: bundleId)
            && appSettings.resolve(\.shellCommands, forBundleId: bundleId, globalDefault: false)
        return ActivationPolicy.isIdle(.init(bundleId: bundleId,
                                             terminalText: terminalText,
                                             fieldHeight: heights?.field,
                                             windowHeight: heights?.window,
                                             shellCommandsEnabled: shellOptIn))
    }

    // MARK: - Generation (newest-wins, deadline-drop)

    private func startGeneration(prefix: String, shellMode: Bool = false, terminalBuffer: String? = nil) {
        let myGen = bumpGeneration()
        activePrefix = prefix
        generationShellMode = shellMode
        generationRTL = TextDirectionDetector.isRightToLeft(prefix)   // #14: once per generation, not per token
        glueGuardMemoKey = nil; glueGuardMemoResult = nil   // fresh prefix -> recompute the glue decision

        // FR-CE-5 (KV reuse): the engine keeps its context warm across calls and diffs the
        // full prefix internally — when `prefix` strictly extends the previous one only the
        // appended tokens are evaluated (the warm ~65 ms path); divergence trims the cache
        // back to the branch point. We just pass the full prefix; reuse happens in the engine.

        // Deadline-drop (FR-CE-7): if no first token by `deadline`, hide silently. Armed
        // on main; disarmed when the first token arrives or the generation is superseded.
        var firstTokenSeen = false
        // Confidence gate (suppress low-probability / flailing completions). Mutated by the engine's
        // onSample callback and read in onToken / on completion — all on the same inferenceQueue thread,
        // so the captured-var box needs no extra locking.
        var gate = ConfidenceGate(firstTokenMinProb: Self.firstTokenMinProb,
                                  meanMinProb: Self.meanMinProb)
        let deadlineWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !firstTokenSeen && self.isCurrent(myGen) {
                self.bumpGeneration()          // supersede the slow run
                self.clearSuggestion()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline, execute: deadlineWork)

        // Tier 2a (mid-word healing): when the caret sits mid-word, back the prompt up to the last clean
        // word boundary and require the model to reproduce the typed stem before its output becomes the
        // ghost — instead of continuing from a fragile subword state where a cheaper wrong token can
        // outrank the right one ("…is gre" → "asy"/greasy vs "at"/great). The required prefix carries the
        // boundary's trimmed separator whitespace too, because the base tokenizer re-emits it as the
        // leading space of the next word ("▁great"); the engine then strips the whole reproduced stem so
        // only the new characters reach the ghost. nil → not mid-word, unchanged behaviour. The constant
        // head also keeps the KV anchor stable while typing within a word (fewer re-prefills).
        var promptPrefix = prefix
        var requiredPrefix: [UInt8]? = nil
        // Runtime kill-switch (default ON): healing fires on most completions (mid-word is the common
        // boundary), so this is the one-flip escape hatch if a beta surfaces a regression — no rebuild
        // (`defaults write com.shadowtype.app shadowtype.midWordHealing -bool NO`).
        let healingOn = (UserDefaults.standard.object(forKey: "shadowtype.midWordHealing") as? Bool) ?? true
        if healingOn, !shellMode, let split = MidWordHealing.split(prefix: prefix) {
            let headTrimmed = Self.trimmingTrailingInlineWhitespace(split.head)
            let trimmedWS = String(split.head.dropFirst(headTrimmed.count))
            promptPrefix = headTrimmed
            requiredPrefix = Array((trimmedWS + split.stem).utf8)
        }
        generationIsHealed = (requiredPrefix != nil)

        // FR-CTX-1/2/3, FR-PA-3: assemble leading context, each block gated by isLicensed + its toggle,
        // then the user's prefix as the forward-from-caret tail. Default Free -> effectivePrompt == prefix,
        // so KV reuse and behavior are unchanged. Shell mode swaps in the few-shot `$ command` framing
        // built from the terminal buffer (the OCR/style/clipboard context blocks don't apply there).
        let effectivePrompt = shellMode
            ? Self.assembleShellPrompt(prefix: promptPrefix, terminalBuffer: terminalBuffer)
            : assembledPrompt(prefix: promptPrefix)
        // Command-shaped sampling for shell mode: deterministic (temp 0.2), single line (stop at "\n",
        // useEngineStopPolicy=false → raw stream, no prose word/sentence caps). Same seq 0 for KV continuity.
        let genParams: SamplingParams = shellMode ? .commandDefaults : .ghostDefaults
        let genMaxTokens = shellMode ? Self.shellMaxTokens : self.maxTokens

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            var acc = ""
            do {
                try self.engine.generate(prompt: effectivePrompt, maxTokens: genMaxTokens,
                                         seqID: 0, params: genParams,
                                         requiredPrefix: requiredPrefix, onToken: { piece in
                    // Cooperative cancel: bail the instant a newer request supersedes us
                    // (FR-CE-4). Checked between every token and (in the engine) between
                    // prefill chunks.
                    guard self.isCurrent(myGen) else { return false }
                    // First-token confidence gate: if the model is already unsure on its first content
                    // token, suppress before anything renders (onSample for that token has already run).
                    if gate.firstTokenRejected {
                        Diag.log("gen: low first-token confidence first=\(gate.firstProbString) -> hide")
                        return false
                    }
                    acc += piece
                    let snapshot = acc
                    // Stop sequence: once a paragraph break (`\n\n`) follows real content, the base model
                    // has "ended" and is starting a fresh template/list (the classic garbage tail). Halt
                    // the decode early — renderSuggestion truncates the display at the same point.
                    let halt = Self.truncatedAtParagraphBreak(snapshot) != snapshot
                    DispatchQueue.main.async {
                        guard self.isCurrent(myGen) else { return }
                        let isFirst = !firstTokenSeen
                        if isFirst {
                            firstTokenSeen = true
                            deadlineWork.cancel()
                            Diag.log("gen: first token -> showing ghost")
                        }
                        // Context re-fire is strictly monotonic: hold while the new stream is a
                        // prefix of the visible ghost, allow only a strict EXTENSION (visible is a
                        // prefix of the new stream — model adding more), and silently DISCARD a
                        // divergent stream. Replacing a held ghost with a divergent completion is
                        // the dominant mid-pause flicker the user perceives ("ghost A → ghost B"),
                        // so the re-fire never repaints in that case — the visible ghost stays.
                        // The hold flag is cleared on clearSuggestion()/cancel()/gen-done, NOT on
                        // stream divergence — divergent tokens just no-op until the gen ends.
                        if self.inContextRefire {
                            switch OverlayRefireDecision.decide(visible: self.suggestionText, snapshot: snapshot) {
                            case .hold, .discard:
                                return
                            case .renderExtension:
                                break    // fall through to the render path; keep inContextRefire true
                            }
                        }
                        // First token renders immediately so the ghost appears without delay; subsequent
                        // tokens are coalesced to ≤1 render per ~33 ms, killing per-token re-anchor
                        // jitter on fast local models without delaying the perceived first-appearance.
                        if isFirst {
                            self.pendingStreamWork?.cancel()
                            self.pendingStreamWork = nil
                            self.pendingStreamSnapshot = nil
                            self.renderSuggestion(snapshot)
                            return
                        }
                        self.pendingStreamSnapshot = snapshot
                        if self.pendingStreamWork == nil {
                            let work = DispatchWorkItem { [weak self] in
                                guard let self else { return }
                                self.pendingStreamWork = nil
                                guard let s = self.pendingStreamSnapshot else { return }
                                self.pendingStreamSnapshot = nil
                                guard self.isCurrent(myGen) else { return }
                                self.renderSuggestion(s)
                            }
                            self.pendingStreamWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + self.streamCoalesceWindow, execute: work)
                        }
                    }
                    return !halt
                }, onSample: { prob, isFirst in
                    gate.record(prob: Double(prob), isFirst: isFirst)
                })
            } catch {
                NSLog("Shadowtype: generate failed: \(error)")
                Diag.log("gen: ERROR \(error)")
            }
            let finalGate = gate
            DispatchQueue.main.async {
                deadlineWork.cancel()
                // Flush any token coalesced for the next ~33 ms — generation is done, no point waiting.
                // During a held re-fire we honour the same monotonic rule the per-token branch uses:
                // commit only if the coalesced snapshot strictly extends the visible ghost; hold or
                // discard otherwise. (Outside a re-fire, render normally as before.)
                if let s = self.pendingStreamSnapshot {
                    self.pendingStreamWork?.cancel()
                    self.pendingStreamWork = nil
                    self.pendingStreamSnapshot = nil
                    if self.isCurrent(myGen) {
                        if self.inContextRefire {
                            if case .renderExtension = OverlayRefireDecision.decide(visible: self.suggestionText, snapshot: s) {
                                self.renderSuggestion(s)
                            }
                        } else {
                            self.renderSuggestion(s)
                        }
                    }
                }
                // Re-fire commit policy: only when the final buffer strictly extends the visible
                // ghost (model produced "hello" → "hello world"). Divergent or shorter `acc` is
                // silently discarded so the visible ghost stays untouched — replacing it would be
                // the very mid-pause flicker the gate exists to kill. The identical-text case is
                // a no-op here (decide returns .hold for equal strings).
                let heldRefire = self.inContextRefire
                self.inContextRefire = false
                if heldRefire, self.isCurrent(myGen), !acc.isEmpty {
                    if case .renderExtension = OverlayRefireDecision.decide(visible: self.suggestionText, snapshot: acc) {
                        self.renderSuggestion(acc)
                    } else {
                        Diag.log("gen: refire divergent -> discard (kept visible ghost)")
                    }
                }
                // Cumulative confidence gate: a completion whose mean token probability is poor reads as
                // word-salad even when each guard above passed; drop it (FR — fewer incoherent ghosts).
                // BUT: never yank a ghost the user is already reading. The mean-reject fires after the
                // full decode, by which point the first-token render at line ~822 may have already
                // committed a partial ghost. Hiding it now is a visible "show → vanish" flash the user
                // perceives as flicker (worse UX than a slightly garbled completion). So the hide only
                // applies when nothing has been committed to screen yet.
                if self.isCurrent(myGen) && !acc.isEmpty && finalGate.meanRejected {
                    if self.suggestionVisible && !self.suggestionText.isEmpty {
                        Diag.log("gen: low mean confidence mean=\(finalGate.meanProbString) -> kept visible ghost")
                    } else {
                        Diag.log("gen: low mean confidence mean=\(finalGate.meanProbString) -> hide")
                        self.clearSuggestion(); return
                    }
                }
                // If the stream produced nothing and is still current, hide.
                if self.isCurrent(myGen) && acc.isEmpty { Diag.log("gen: produced nothing (deadline/EOG)"); self.clearSuggestion() }
                else if self.isCurrent(myGen) { Diag.log("gen: done len=\(acc.count) mean=\(finalGate.meanProbString)"); Diag.logContent("gen: done acc=\"\(acc.prefix(40))\"") }
            }
        }
    }

    // MARK: - Cache warming (FR-CE-8)

    // Call on focus-in (NSWorkspace activation / AX focus change) so the KV cache is warm
    // before the first keystroke needs a suggestion (FR-CE-8). Background-prefills the existing
    // field text into `cachedTokens` so the next generate() reuses it (FR-CE-5) instead of paying
    // the cold prefill. Requests a single token then discards it — the side effect (warm context)
    // is the goal.
    func warmFocus() {
        guard isEnabled, engine.isLoaded, !context.isSecureField() else { return }
        if let appRules, !appRules.isEnabled(bundleId: context.frontmostBundleId,
                                             domain: context.frontmostDomainHost()) { return }

        // New focus/app: drop the previous field's OCR context so stale screen text can't leak across the
        // switch (the capture below + on the first keystroke repopulates it for THIS window). Done before
        // the prefix guard so it also resets when focusing an empty field. fire() then holds the first
        // guess until this focus's capture lands (see the .pending gate in fire()/refreshOCRContextIfEnabled).
        if useScreenOCR { storeOCRCache(nil); ocrCaptureState = .idle }

        guard let prefix = context.currentPrefix(), !prefix.isEmpty else { return }

        // FR-CTX-1 (gated, default OFF): kick the on-screen OCR capture for this focus. fire() re-captures
        // on each typing pause too (so scrolling is reflected); storeOCRCache's change-guard keeps the
        // prepended OCR block — and thus the KV cache — stable while the visible text is unchanged.
        refreshOCRContextIfEnabled()
        // FR-CTX-3: snapshot the style hint on focus-in too, so it stays stable through the typing burst
        // (warm KV) and its sort stays off the per-keystroke path.
        refreshStyleHintIfEnabled()

        let myGen = bumpGeneration()
        // Warm the SAME prompt startGeneration() will use (FR-CE-5): assemble the leading-context blocks
        // (instructions/style/clipboard/OCR, all paid-gated) on main — exactly as startGeneration does at
        // its dispatch point — so the first real keystroke after a focus switch reuses this warm cache
        // instead of paying a cold prefill. Warming bare `prefix` would leave the cache mismatched for
        // licensed users with any context source on.
        let warmPrompt = assembledPrompt(prefix: prefix)
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            _ = myGen
            // One token is enough to force the full prefill into the KV cache; we stop immediately and
            // never display warm-up output (side effect = warm ctx).
            try? self.engine.generate(prompt: warmPrompt, maxTokens: 1) { _ in false }
        }
    }

    // FR-LM-1: swap the active model SAFELY. InferenceEngine has no internal locking — its ctx/model are
    // only safe to touch on `inferenceQueue` (the one queue generate()/warmFocus() use). An unload/load
    // on any other thread can free the llama context out from under an in-flight llama_decode →
    // use-after-free. So: cancel the in-flight generation on main (supersede + cooperative-cancel), then
    // dispatch unload+load onto inferenceQueue, where it is serialized AFTER any running generate(). If
    // the new model fails to load, fall back to `fallbackPath` so the engine isn't left unloaded (which
    // would silently kill all completions until relaunch). `onComplete(true/false)` runs on main.
    func reloadModel(at path: String, fallbackPath: String?, onComplete: @escaping (Bool, String?) -> Void) {
        cancel()   // main: bumpGeneration + engine.requestCancel + hide ghost; the running decode bails fast
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            self.engine.unload()
            var ok = true
            // The real load failure (e.g. Metal context init on a new GPU/OS) — surfaced to the
            // Models pane so it stops mislabeling an engine failure as a disk/network download error.
            var loadError: String?
            do {
                try self.engine.load(modelPath: path)
            } catch {
                NSLog("Shadowtype: model load failed for \(path): \(error)")
                ok = false
                loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if let fallbackPath {
                    do {
                        try self.engine.load(modelPath: fallbackPath)
                        NSLog("Shadowtype: restored previous model after failed swap")
                    } catch {
                        NSLog("Shadowtype: fallback model load ALSO failed: \(error) — engine unloaded")
                    }
                }
            }
            let success = ok
            let reason = loadError
            DispatchQueue.main.async { onComplete(success, reason) }
        }
    }

    // Models → "Unload model when idle": free the resident model + Metal context after an idle window.
    // Like reloadModel(), the unload MUST run on `inferenceQueue` (the engine is not thread-safe), so we
    // cancel any in-flight generation on main first, then serialize the unload after it. Safe to call
    // when already unloaded (engine.unload() is idempotent). AppDelegate reloads lazily on next activity.
    func unloadModel() {
        cancel()
        inferenceQueue.async { [weak self] in self?.engine.unload() }
    }

    // True when the engine has a model resident. AppDelegate reads this to decide whether an idle-unload
    // happened and a lazy reload is needed before the next suggestion.
    var isModelLoaded: Bool { engine.isLoaded }

    // CONTRACT: exact name `isEngineLoaded` — another agent's code (rewrite/menu guards, see the
    // engine.isLoaded gate in rewrite()) compiles against this property. Whether the inference engine
    // is loaded and ready to generate. Alias of isModelLoaded; keep both stable.
    var isEngineLoaded: Bool { engine.isLoaded }

    // MARK: - Accept (FR §M4 — Tab/word accept -> Injector)

    // Inject the next whole word of the live suggestion. Returns words injected (0 if none).
    // FR-EM-1: when the live suggestion is an emoji, insert the emoji (replacing the typed shortcode
    // run) and count 0 words — emojis never touch the WordMeter.
    func acceptWord() -> Int {
        if let fix = correctionSuggestion { return acceptCorrection(fix) }
        if let emoji = emojiSuggestion { return acceptEmoji(emoji) }
        guard suggestionVisible, !suggestionText.isEmpty else { return 0 }
        let word = nextWord(from: suggestionText)
        guard !word.isEmpty else { return 0 }
        let injected = inject(word)
        guard injected else { return 0 }
        countAcceptanceOnce()

        // Accepting commits the user to this suggestion: supersede any still-in-flight generation
        // first, so a late streamed token can't overwrite the advanced remainder with the full
        // accumulator (which would re-show — and let a second Tab re-inject + double-count — the
        // word just accepted).
        bumpGeneration()
        engine.requestCancel()

        // Advance the displayed suggestion past the accepted word so the remainder stays
        // ghosted (it now sits after the freshly-typed text).
        let remainder = String(suggestionText.dropFirst(word.count))
        if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearSuggestion()
        } else {
            renderSuggestion(remainder, checkPrefixDup: false, caretOverride: remainderAnchor(after: word))
            // Caret advanced past the accepted word — re-snapshot end-of-line so the next Right
            // Arrow accept gate reflects the new caret position (the suggestionVisible.didSet
            // rising-edge push doesn't fire here since visibility was already true).
            onCaretAtLineEndChanged?(context.caretAtLineEnd())
        }
        // Return the REAL word count (0 allowed): a whitespace/punctuation-only accepted chunk is not a
        // word and must not inflate the meter. Callers treat 0 as "nothing to count", never as failure
        // (AppDelegate.applyAccept just skips the increment) — same contract as the 0-word emoji path.
        let n = WordMeter.wordCount(in: word)
        recordStyle(word)   // FR-CTX-3: learn from the accepted phrasing (gated inside).
        return n
    }

    // Inject the whole current line of the suggestion (up to the first newline).
    func acceptLine() -> Int {
        if let fix = correctionSuggestion { return acceptCorrection(fix) }
        if let emoji = emojiSuggestion { return acceptEmoji(emoji) }
        guard suggestionVisible, !suggestionText.isEmpty else { return 0 }
        let line: String
        if let nl = suggestionText.firstIndex(of: "\n") {
            line = String(suggestionText[..<nl])
        } else {
            line = suggestionText
        }
        guard !line.isEmpty else { return 0 }
        guard inject(line) else { return 0 }
        countAcceptanceOnce()
        // Supersede any in-flight generation before clearing, so a late token can't re-show the
        // just-accepted line (which a stray Tab could then re-inject).
        bumpGeneration()
        engine.requestCancel()
        clearSuggestion()
        recordStyle(line)   // FR-CTX-3: learn from the accepted phrasing (gated inside).
        return WordMeter.wordCount(in: line)
    }

    // Local acceptance-rate counter (Statistics only): count the currently-shown completion as accepted
    // exactly once, even when the user Tab-accepts it word-by-word. Reset when the next ghost is shown.
    private func countAcceptanceOnce() {
        guard !currentSuggestionAccepted else { return }
        currentSuggestionAccepted = true
        wordMeter?.recordSuggestionAccepted()
        // Count distinct accepted suggestions toward retiring the Tab hint (stop writing once retired).
        if tabHintAcceptCount < tabHintThreshold { tabHintAcceptCount += 1 }
    }

    // FR-CTX-3 (paid): fold a genuine accepted phrasing into the on-device style profile. Gated behind
    // isLicensed && styleProfileEnabled. Skips empty/whitespace accepts (consistent with the 0-word
    // emoji/correction paths, which never reach here). StyleProfile itself ignores >12-word pastes.
    private func recordStyle(_ text: String) {
        guard isLicensed, styleProfileEnabled, let styleProfile else { return }
        let bundleId = context.frontmostBundleId
        // Per-app "Collect inputs for personalization": global learning is already on (styleProfileEnabled),
        // so an app contributes unless the user set its tri-state to Off.
        guard appSettings.resolve(\.collectInputs, forBundleId: bundleId, globalDefault: true) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        styleProfile.recordAccepted(trimmed, bundleId: bundleId)
    }

    // FR-IN-2/3: prefer the direct-AX insert into the live focused element (atomic, no synthetic
    // events); the Injector falls back to Unicode typing when AX writes are refused (many
    // Electron/Chromium fields) or no element is focused. Returns true on success.
    private func inject(_ text: String) -> Bool {
        guard let injector else { return false }
        return injector.inject(text, into: context.focusedElement())
    }

    // First word of `text` including its leading whitespace, so injection preserves spacing
    // (e.g. " world" stays separated from the prior token).
    private func nextWord(from text: String) -> String {
        var idx = text.startIndex
        // consume leading whitespace
        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        // consume the word body
        while idx < text.endIndex, !text[idx].isWhitespace { idx = text.index(after: idx) }
        return String(text[text.startIndex..<idx])
    }

    // MARK: - Overlay (main only)

    // Anchor for the remainder ghost after a word accept. A synthetic-injection host (web/Electron,
    // where AX writes are refused and the Injector types the word as CGEvents) applies the keystrokes
    // ASYNCHRONOUSLY, so the live caret is still at the pre-accept spot the instant we re-render — the
    // remainder would paint OVER the word just accepted (Slack/Gmail). Advance the previous anchor by the
    // rendered width of the accepted word instead; that is exact when the ghost font matches the host
    // (FR-OV-4). Native AX injection moves the caret synchronously, so when the live caret HAS advanced
    // past the old anchor we trust the real read (handles wraps/scroll the prediction can't).
    private func remainderAnchor(after word: String) -> CGRect? {
        guard let base = lastRenderedOverlay?.caretRect, !base.isNull else {
            return context.caretRectOnScreen()
        }
        // Native AX insert advances the caret SYNCHRONOUSLY, so the live read is already correct. Web/
        // Electron injection is asynchronous synthetic keystrokes — the host hasn't moved the caret yet,
        // so a live read returns the PRE-accept position and the remainder paints over the word just
        // typed (the Slack symptom). Decide by the injection SURFACE (the marker-protocol node is the
        // synthetic path) rather than a caret delta, which is unreliable on Electron's noisy caret reads.
        let synthetic = context.focusedElement().map { Injector.isWebTextNode($0) } ?? false
        if !synthetic, let live = context.caretRectOnScreen(), !live.isNull {
            return live
        }
        // Predict: advance the anchor by the accepted word's width in the SAME font the overlay drew the
        // ghost with, so the remainder lands right after where the host renders the accepted word.
        let font = hostFont(caretHeight: base.height)
            ?? NSFont.systemFont(ofSize: max(11, base.height > 0 ? base.height / 1.17 : 13))
        let advance = (word as NSString).size(withAttributes: [.font: font]).width
        let x = base.minX + (generationRTL ? -advance : advance)
        Diag.log("remainderAnchor: synthetic=\(synthetic) base=\(Int(base.minX)) adv=\(Int(advance)) -> x=\(Int(x))")
        return CGRect(x: x, y: base.minY, width: 0, height: base.height)
    }

    private func renderSuggestion(_ rawText: String, checkPrefixDup: Bool = true, caretOverride: CGRect? = nil) {
        // Rising edge: a fresh completion (not the streamed re-render of a growing ghost, nor the
        // remainder re-render after a word accept — both keep the ghost already-visible). Drives the
        // local acceptance-rate counter and resets the "already accepted" flag for the new suggestion.
        let wasVisible = suggestionVisible
        // Strip cosmetic markup the base (pretrained) model leaks from its web/Markdown training
        // (`<strong>`, `<code>`, `**`, backticks). Done ONCE here so the displayed ghost and the
        // text that Tab/⌥Tab inject (both read `suggestionText`) stay identical. Idempotent, so the
        // re-render of the remainder after an accept is a no-op.
        var text: String
        if generationShellMode {
            // Shell-command mode: bypass EVERY prose transform — markup strip (backticks = command
            // substitution), list-marker strip (leading `-` = flag), glue/leading-space reconcile, and the
            // language guards all corrupt shell syntax. Keep exactly one line, then apply the destructive-
            // command guard on the JOINED command (typed current line + suggestion) so a split `rm -rf ` +
            // `/` is still caught.
            text = Self.truncatedAtNewline(rawText)
            let fullCommand = Self.shellCurrentLine(activePrefix) + text
            if ShellCommandGuard.isDangerous(fullCommand: fullCommand) {
                Diag.log("render: dangerous command -> hide")
                clearSuggestion(); return
            }
            guard text.contains(where: { !$0.isWhitespace }) else {
                Diag.log("render: shell empty -> hide")
                clearSuggestion(); return
            }
        } else {
        text = Self.truncatedAtParagraphBreak(
            Self.strippingLeadingListMarker(Self.sanitizedSuggestion(rawText)))
        // The prefix-relative transforms assume `text` is a FRESH continuation of `activePrefix`. They
        // must NOT run on a Tier-2a healed generation (the engine already regenerated the typed word from
        // a clean boundary and stripped the reproduced stem, so `text` is the final word-completion tail —
        // reconciling a leading space would turn "at" into " at") nor on the post-accept remainder
        // re-render (checkPrefixDup:false; already spaced, stale prefix).
        let prefixTransforms = checkPrefixDup && !generationIsHealed
        // Reconcile the model's leading separator space with the live prefix so Tab-accept inserts a
        // proper word break. Drop a spurious mid-word glue fragment ("...pot" + "er fer..." -> "poter"):
        // a no-leading-space first token that extends an already-complete word into a non-word — now the
        // common case healing handles directly, so this is the fallback for non-healed continuations.
        if prefixTransforms { text = applyGlueGuard(text, prefix: activePrefix) }
        if prefixTransforms { text = Self.reconcileLeadingSpace(suggestion: text, prefix: activePrefix) }
        guard !text.isEmpty, !Self.isLowValueSuggestion(text) else {
            Diag.log("render: low-value -> hide")
            clearSuggestion(); return
        }
        // Suppress a completion that just loops back over text already typed ("thanks for " +
        // "for reading" -> stutter on inject). Skipped on the accept-remainder re-render, whose
        // `activePrefix` is stale (the accepted word isn't folded into it).
        if prefixTransforms, Self.isPrefixDuplicate(suggestion: text, prefix: activePrefix) {
            Diag.log("render: prefix-duplicate -> hide")
            clearSuggestion(); return
        }
        // Language-drift guard: a base model sometimes switches language mid-stream (an English ghost in a
        // Spanish doc). Suppress only on a confident, clearly-different language read (skip on the stale
        // remainder re-render). Conservative — never fires on a short/ambiguous prefix.
        if prefixTransforms, Self.languageDrifts(prefix: activePrefix, suggestion: text) {
            Diag.log("render: lang-drift -> hide")
            clearSuggestion(); return
        }
        // Context-language guard: when the surrounding conversation has a confident dominant language,
        // suppress a completion that drifts to a DIFFERENT language (a base model following the
        // immediate prefix over the far-away Context: block — generic Spanish in a Catalan thread). The
        // steer above tries to match; this hides what still drifts (user choice: match convo, else hide).
        // Catches the short-prefix case the prefix-based languageDrifts can't, since the context read is
        // long + high-confidence. Skipped on the stale accept-remainder re-render.
        if prefixTransforms, let target = generationContextLang,
           Self.suggestionConflictsWithContext(suggestion: text, contextLang: target) {
            Diag.log("render: context-lang conflict -> hide")
            clearSuggestion(); return
        }
        }
        // Drop leading newlines (the model often "ends" the line then starts a template) and require
        // at least one printable char — otherwise the ghost would render as invisible whitespace.
        let display = String(text.drop(while: { $0 == "\n" || $0 == "\r" }))
        guard display.contains(where: { !$0.isWhitespace }) else {
            Diag.log("render: blank/whitespace-only -> hide")
            clearSuggestion(); return
        }
        let opacity = capOpacity() ?? 1
        suggestionText = text
        // FR-OV-3/6: anchor at the live caret; OverlayRenderer falls back to a chip if nil. A word-accept
        // remainder re-render passes a predicted anchor (see remainderAnchor) because the live caret is
        // stale until an async synthetic-injection host applies the keystrokes.
        let caret = caretOverride ?? (context.caretRectOnScreen() ?? .null)
        let caretDesc = caret.isNull ? "null" : "\(Int(caret.minX)),\(Int(caret.minY))"
        Diag.log("render: show len=\(display.count) caret=\(caretDesc)")
        Diag.logContent("render: show \"\(display.prefix(40))\"")
        // #2: hold the existing panel geometry across reconcile ticks (every streamed token, the
        // post-accept remainder re-render) unless something the user can see actually changed — focus
        // session, displayed text, caret rect, fade opacity, RTL side, or host font. This kills the
        // post-accept "shift then snap back" jitter from a drifted AX caretRect while still re-anchoring
        // on a real change. #11: anchor the ghost left of the caret in a right-to-left field.
        let font = hostFont(caretHeight: caret.height)
        let candidate = OverlayStabilityGate.Rendered(
            text: display, caretRect: caret, focusSeq: context.focusChangeSequence,
            opacity: opacity, rtl: generationRTL, fontKey: OverlayStabilityGate.fontKey(font))
        if OverlayStabilityGate.shouldRePresent(last: lastRenderedOverlay, candidate: candidate) {
            // FR-OV-4: match the host text size so the ghost reads as part of the field.
            emit(text: display, at: caret, font: font, opacity: opacity, rtl: generationRTL)
            lastRenderedOverlay = candidate
        } else {
            Diag.log("render: hold overlay geometry (stable)")
        }
        if !wasVisible {
            currentSuggestionAccepted = false
            wordMeter?.recordSuggestionShown()
        }
        suggestionVisible = true
        // Cotypist-pattern coexistence nudge for Gmail's Smart Compose. Gated by the per-session/
        // dismiss pre-gate before any AX read so the steady state (already prompted or dismissed) is
        // free. See SmartComposeNudge for the detection heuristic.
        maybeNoteSmartComposeOverlap()
    }

    // Smart Compose detection — runs on a SUCCESSFUL render only (the ghost actually went up). Mirrors
    // the AXNudge pre-gate flow: cheap pre-checks before the AX value read, threshold-driven post.
    private func maybeNoteSmartComposeOverlap() {
        guard smartComposeNudgeEnabled else { return }
        guard SmartComposeNudgeStore.shared.mayStillPrompt() else { return }
        guard let host = context.frontmostDomainHost(),
              SmartComposeNudge.isApplicableHost(host) else { return }
        let fieldValue = context.focusedElementText()
        if SmartComposeNudge.detectsOverlap(fieldValue: fieldValue,
                                            prefix: activePrefix,
                                            suggestion: suggestionText) {
            if SmartComposeNudgeStore.shared.noteOverlap() {
                Diag.log("smartCompose: nudge fired (consecutive overlap threshold reached)")
                NotificationCenter.default.post(name: .shadowtypeShowSmartComposeNudge, object: nil)
            }
        } else {
            SmartComposeNudgeStore.shared.noteNoOverlap()
        }
    }

    // The host text font for the ghost (FR-OV-4): the exact AX font at the caret when the app exposes
    // it, else a system font sized from the caret line height (≈1.17× point size for typical fonts) so
    // web/Electron fields still get a size-matched ghost. nil => OverlayRenderer keeps its default.
    private func hostFont(caretHeight: CGFloat) -> NSFont? {
        if let f = context.caretFont() {
            Diag.log("font: host \(f.fontName) \(String(format: "%.1f", f.pointSize))pt (caretH=\(Int(caretHeight)))")
            return f
        }
        // #1: floor the caret height to the smallest seen this focus session before deriving the size,
        // so a single AX poll that returns the coarse full-field-height fallback can't size a giant ghost.
        let stableHeight = ghostFontStabilizer.stabilizedCaretHeight(caretHeight,
                                                                     focusSessionKey: context.focusChangeSequence)
        guard let base = Self.ghostFontSize(caretHeight: stableHeight) else {
            Diag.log("font: none (caretH=\(Int(caretHeight))) -> overlay default")
            return nil
        }
        // Some native composers (Telegram) report a padded box height with no real caret/font, so the
        // estimate overshoots; scale it down per-app and re-clamp to the readable minimum.
        let scale = Self.ghostFontScale(forBundleId: context.frontmostBundleId)
        let size = max(11, round(base * scale))
        Diag.log("font: estimate \(String(format: "%.1f", size))pt from caretH=\(Int(stableHeight)) (raw=\(Int(caretHeight)) scale=\(String(format: "%.2f", scale)))")
        return NSFont.systemFont(ofSize: size)
    }

    // FR-OV-4 sizing math (pure, testable): when the host AX font is unavailable, derive a point size
    // from the caret line height (≈1.17× point size for typical fonts), clamped to a readable minimum.
    // nil for a non-positive caret height (no usable geometry) → OverlayRenderer keeps its default.
    static func ghostFontSize(caretHeight: CGFloat) -> CGFloat? {
        guard caretHeight > 0 else { return nil }
        // Clamp to a readable range. The upper bound is a hard backstop against a bogus caret height
        // (e.g. a multi-line field's full box height) sizing a giant ghost — body text is never 700pt.
        return min(maxGhostFontSize, max(11, round(caretHeight / 1.17)))
    }

    static let maxGhostFontSize: CGFloat = 32

    // Known native composers whose AX box height includes heavy vertical padding, so the estimate-branch
    // font (caretHeight/1.17) overshoots the real text. Scale the estimated size down by an app-tuned
    // factor. Applied ONLY in the estimate branch (bypassed whenever the app exposes a real AX font).
    // 1.0 = no change (default).
    static func ghostFontScale(forBundleId bundleId: String?) -> CGFloat {
        switch bundleId {
        case "ru.keepcoder.Telegram": return 0.50   // tune from diag (caretH ~ box height incl. padding)
        default: return 1.0
        }
    }

    // FR-AC-1 display: the X origin for the correction ghost — shifted LEFT of the caret by the rendered
    // width of the mistyped `run`, so the fix previews IN PLACE over the typo instead of appended after
    // the caret (which would read as "tehthe"). Pure (NSString sizing is window-server-independent).
    static func correctionGhostMinX(caretMinX: CGFloat, run: String, font: NSFont?) -> CGFloat {
        let f = font ?? NSFont.systemFont(ofSize: 13)
        let width = (run as NSString).size(withAttributes: [.font: f]).width
        return caretMinX - width
    }

    private func clearSuggestion() {
        suggestionText = ""
        emojiSuggestion = nil
        emojiQueryLength = 0
        correctionSuggestion = nil
        correctionRun = nil
        overlay.hide()
        overlayPresented = false    // nothing on screen now → next emit() must actually show
        untrackOverlay()            // #2: next show re-anchors from scratch
        // Drop the emit-dedup record so a user-initiated clear+retype of the same text still shows.
        // Skipped during a context re-fire (the whole point of the re-fire is to suppress the
        // identical re-show — clearing here would defeat that across the cancel→fire boundary).
        if !inContextRefire { lastEmitState = nil }
        // The hold flag is single-shot: any explicit clear during/after a re-fire (deadline-drop,
        // confidence reject, fire() early-out from a guard) must end the hold so the next genuine
        // emission isn't suppressed by stale state. The gen-done handler also clears it on success.
        inContextRefire = false
        // Any coalesced token render queued for the now-gone ghost is moot — drop it.
        pendingStreamWork?.cancel()
        pendingStreamWork = nil
        pendingStreamSnapshot = nil
        suggestionVisible = false   // didSet notifies the Tab swallow only on transition
    }

    // MARK: - Host font watch (FR-OV-4)

    private func startFontWatch() {
        guard fontWatchMonitor == nil else { return }
        fontWatchMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            // The host applies the new font a beat after the click lands; let AX settle, then re-read.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.revalidateHostFont()
            }
        }
    }

    private func stopFontWatch() {
        if let m = fontWatchMonitor { NSEvent.removeMonitor(m) }
        fontWatchMonitor = nil
    }

    // Re-read the host font for the visible completion ghost; re-render in place only if it changed.
    // No regeneration — same text, same focus session — so it cannot churn or shift the suggestion.
    // Scope: only the gate-tracked completion ghost (lastRenderedOverlay != nil). Emoji/correction
    // ghosts untrack themselves, so they're skipped here.
    private func revalidateHostFont() {
        guard suggestionVisible, let last = lastRenderedOverlay, !last.text.isEmpty else { return }
        guard context.focusChangeSequence == last.focusSeq else { return }
        let caret = context.caretRectOnScreen() ?? last.caretRect
        let font = hostFont(caretHeight: caret.height)
        let newKey = OverlayStabilityGate.fontKey(font)
        guard newKey != last.fontKey else { return }
        Diag.log("font: host font changed while visible -> re-render (\(last.fontKey ?? "default") -> \(newKey ?? "default"))")
        // Bypass emit()'s identical-text dedup: the text is unchanged by design, so emit() would drop
        // this deliberate in-place re-font. Drive overlay.show directly and resync the gate snapshot.
        overlay.show(text: last.text, at: caret, font: font, opacity: last.opacity, rtl: last.rtl,
                     showHint: tabHintActive)
        lastRenderedOverlay = OverlayStabilityGate.Rendered(
            text: last.text, caretRect: caret, focusSeq: last.focusSeq,
            opacity: last.opacity, rtl: last.rtl, fontKey: newKey)
    }

    // Single owner of the stability-gate snapshot reset. The emoji/correction ghosts and clearSuggestion
    // all bypass the gate, so they must drop the last-rendered snapshot or the next completion render
    // could wrongly HOLD a stale frame (#12). Centralized so no show-path can forget it.
    private func untrackOverlay() {
        lastRenderedOverlay = nil
    }

    // Single funnel for every overlay.show() in the file. Catches an identical re-emission on the same
    // focus session within a short window — the dominant "shows twice" pattern when an OCR re-fire (or
    // any path that clears and re-renders) regenerates the exact text the user just saw. The
    // OverlayStabilityGate runs upstream for caret/font geometry; this gate runs at the metal boundary
    // and persists across clearSuggestion()/untrackOverlay() so the gate's reset can't defeat it.
    @discardableResult
    private func emit(text: String, at caret: CGRect, font: NSFont?, opacity: CGFloat, rtl: Bool) -> Bool {
        let focusSeq = context.focusChangeSequence
        let now = ProcessInfo.processInfo.systemUptime
        // Drop a duplicate re-show ONLY while that ghost is still on screen (overlayPresented). The dedup
        // record is kept across a re-fire's clearSuggestion() — without the presence gate it could suppress
        // a show with nothing visible, leaving suggestionVisible=true over an empty field (phantom accept).
        if OverlayEmitDedup.shouldDrop(last: lastEmitState, text: text, focusSeq: focusSeq, now: now,
                                       presented: overlayPresented) {
            Diag.log("emit: dedup identical within window len=\(text.count)")
            return false
        }
        overlay.show(text: text, at: caret, font: font, opacity: opacity, rtl: rtl, showHint: tabHintActive)
        overlayPresented = true
        lastEmitState = OverlayEmitDedup.State(text: text, focusSeq: focusSeq, emittedAt: now)
        return true
    }

    // MARK: - Emoji mode (FR-EM-1)

    // Show `emoji` as the ghost; remember the typed `:shortcode` run length so accept can delete it.
    private func showEmoji(_ emoji: String, queryLength: Int) {
        let opacity = capOpacity() ?? 1
        emojiSuggestion = emoji
        emojiQueryLength = queryLength
        suggestionText = emoji
        let caret = context.caretRectOnScreen() ?? .null
        emit(text: emoji, at: caret, font: hostFont(caretHeight: caret.height), opacity: opacity, rtl: false)
        untrackOverlay()                // emoji ghost isn't tracked by the stability gate
        suggestionVisible = true
    }

    // Replace the typed `:shortcode` run with the emoji via the Injector's atomic before-caret replace.
    // Counts 0 words (FR-EM-1). Shortcodes are ASCII, so utf16 == keystroke count == emojiQueryLength.
    private func acceptEmoji(_ emoji: String) -> Int {
        guard let injector else { return 0 }
        guard injector.replaceBeforeCaret(utf16Length: emojiQueryLength, keystrokeCount: emojiQueryLength,
                                          with: emoji, in: context.focusedElement()) else { return 0 }
        clearSuggestion()
        return 0
    }

    // MARK: - Autocorrect mode (FR-AC-1, paid)

    // Show `fix` as a special correction ghost over the mistyped `run`. Unlike a forward completion the
    // correction REPLACES already-typed text, so the ghost is drawn shifted LEFT by the run's rendered
    // width to sit over the typo (rather than appended after the caret, which would read as "tehthe").
    // Mirrors showEmoji() — never calls the model. `run` is the raw mistyped token (its utf16/keystroke
    // lengths drive the atomic delete on accept).
    private func showCorrection(_ fix: String, run: String) {
        let opacity = capOpacity() ?? 1
        correctionSuggestion = fix
        correctionRun = run
        suggestionText = fix
        var caret = context.caretRectOnScreen() ?? .null
        let font = hostFont(caretHeight: caret.height)
        // Shift the ghost left over the mistyped run so it previews the replacement in place (FR-AC-1).
        if !caret.isNull {
            caret.origin.x = Self.correctionGhostMinX(caretMinX: caret.minX, run: run, font: font)
        }
        emit(text: fix, at: caret, font: font, opacity: opacity, rtl: false)
        untrackOverlay()                // correction ghost isn't tracked by the stability gate
        suggestionVisible = true
    }

    // Replace the mistyped trailing token with the fix atomically (FR-AC-1): the Injector selects the
    // run before the caret and overwrites it in one AX op (or falls back to ordered delete+type on
    // web/Electron fields) — no async-backspace-vs-sync-read race. Counts 0 words (mirror acceptEmoji,
    // never touch the WordMeter). utf16 length drives the AX range; grapheme count drives the fallback
    // Delete presses.
    private func acceptCorrection(_ fix: String) -> Int {
        guard let injector, let run = correctionRun else { return 0 }
        guard injector.replaceBeforeCaret(utf16Length: run.utf16.count, keystrokeCount: run.count,
                                          with: fix, in: context.focusedElement()) else { return 0 }
        clearSuggestion()
        return 0
    }

    // MARK: - OCR context (FR-CTX-1, gated)

    // Refresh the style-hint snapshot on focus-in (FR-CTX-3). Computes the (sorted) hint once off the
    // per-keystroke path; assembledPrompt then reads the cached string. nil when not licensed/disabled/empty.
    private func refreshStyleHintIfEnabled() {
        let budget = Self.styleHintChars(forStrength: personalizationStrength)
        guard isLicensed, styleProfileEnabled, budget > 0, let styleProfile else {
            styleHintLock.lock(); styleHintCache = nil; styleHintLock.unlock(); return
        }
        let hint = styleProfile.styleHint(maxChars: budget)
        styleHintLock.lock(); styleHintCache = hint; styleHintLock.unlock()
    }

    // Map the Personalization strength (0...3) to a style-hint char budget. 0 disables the hint
    // entirely; higher steps prepend more characteristic phrasing, biasing generation harder toward
    // the user's voice. Pure + testable (no AX/model). 200 (strength 2) is the .medium anchor.
    static func styleHintChars(forStrength strength: Int) -> Int {
        switch max(0, min(3, strength)) {
        case 0:  return 0
        case 1:  return 100
        case 2:  return 200
        default: return 400
        }
    }

    private func refreshOCRContextIfEnabled() {
        guard useScreenOCR else { return }
        let maxChars = ocrContextChars

        // AX-FIRST: in a browser/web host, read the visible page text directly via Accessibility —
        // exact text (no OCR errors), no Screen Recording permission, synchronous (so browsers never
        // hit the .pending defer). The shared cleanup in assembledPrompt strips the user's draft +
        // chrome regardless of source. Only fall back to OCR when there's no web area (native apps).
        if let ax = context.pageContextText(), !ax.isEmpty {
            // Denoise (drop chrome lines) + keep the tail (nearest the caret), mirroring the OCR
            // path's cleanup so AX and OCR text are interchangeable downstream. The shared dedup in
            // assembledPrompt then strips the user's own draft + the document echo.
            // dropShortLines:false — AX text is exact, so keep short signature/name rows the model
            // needs (the OCR-only chrome rule would otherwise discard them).
            let text = ScreenContextProvider.clamp(
                ScreenContextProvider.denoise(ax, dropShortLines: false), to: pageContextChars)
            let changed = storeOCRCache(text)
            ocrCaptureState = .ready
            Diag.log("pagectx: ax raw=\(ax.count) kept=\(text?.count ?? -1) changed=\(changed)")
            Diag.logContent("pagectx: ax head=\"\(ax.prefix(200))\"")
            if changed { maybeRefireForContext() }
            return
        }

        guard let screenContext else { return }
        // Arm the first-capture gate only when we have NO context yet for this focus; a re-capture while
        // context already exists must not flip back to .pending (that would hide the warm, stale ghost).
        if ocrCache == nil { ocrCaptureState = .pending }
        // Discard a capture that lands after focus has moved to another app.
        let capturedBundleId = context.frontmostBundleId
        Task { [weak self] in
            let text = await screenContext.recentText(maxChars: maxChars)
            guard let self else { return }
            await MainActor.run {
                guard self.context.frontmostBundleId == capturedBundleId else { return }
                let changed = self.storeOCRCache(text)
                self.ocrCaptureState = .ready
                Diag.log("ocr: refresh got \(text?.count ?? -1) chars changed=\(changed)")
                // Fresh context for the current viewport → re-fire so the ghost reflects it (closes the
                // focus-in race + scroll staleness). Bounded to ONE upgrade per prefix so a dynamic
                // screen can't keep regenerating and cycling the ghost during a pause.
                if changed { self.maybeRefireForContext() }
            }
        }
    }

    // Update the OCR context cache, returning whether it MEANINGFULLY changed. OCR jitter (reflowed line
    // breaks, trailing spaces) must not count as a change, or every re-capture would shift the prompt's
    // leading `Context:` tokens and force a cold prefill on the next keystroke (FR-CE-5). When unchanged
    // we keep the existing value so KV stays warm and the caller skips the re-fire.
    @discardableResult
    private func storeOCRCache(_ text: String?) -> Bool {
        ocrLock.lock(); defer { ocrLock.unlock() }
        if Self.ocrTextEquivalent(ocrCache, text) { return false }
        ocrCache = text
        return true
    }

    // Two OCR blocks are equivalent when they match after collapsing all whitespace/newline runs to a
    // single space and trimming — so cosmetic OCR reflow doesn't read as a content change. Pure + testable.
    static func ocrTextEquivalent(_ a: String?, _ b: String?) -> Bool {
        normalizeOCRForCompare(a) == normalizeOCRForCompare(b)
    }
    static func normalizeOCRForCompare(_ s: String?) -> String {
        guard let s else { return "" }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Re-fire generation for a freshly-changed on-screen context — but at most ONCE per prefix, so a
    // dynamic screen can't keep regenerating and cycling the ghost while the user is paused. The cache
    // is already updated (storeOCRCache), so the next keystroke still uses the latest context.
    private func maybeRefireForContext() {
        guard Self.shouldRefireForContext(count: contextRefireCount, max: Self.maxContextRefires) else {
            Diag.log("ocr: skip re-fire (cap reached)")
            return
        }
        contextRefireCount += 1
        // Flip the silent-hold flag so the upcoming generation can hold the visible ghost while its
        // tokens reproduce the prior suggestion (the dominant "regenerates the same text" case after
        // an OCR-context refresh). Cleared on stream divergence or in the gen-done handler.
        inContextRefire = suggestionVisible && !suggestionText.isEmpty
        fire()
    }

    // Pure cap decision (testable): allow the context-upgrade re-fire only until the per-focus-session
    // cap is reached. cancel() resets the count on each keystroke/focus change/force-activate, so a new
    // typing action gets exactly one upgrade and a sustained pause gets none after the first — immune to
    // the prefix-read drift that defeated the earlier per-prefix latch.
    static func shouldRefireForContext(count: Int, max: Int) -> Bool {
        count < max
    }

    // Pure (testable): on a web-mail host, strip the trailing quoted-reply tail of `prefix`. Outside
    // web mail or with a nil prefix, returns the input unchanged — so the email-specific rule never
    // touches normal prose contexts. Used as the prompt prefix when the caret sits inside or below the
    // quoted-history block (Gmail "Show trimmed content"), preventing a ghost that just keeps quoting.
    static func prefixAfterEmailQuoteStrip(_ prefix: String?, host: String?) -> String? {
        guard let p = prefix, ActivationPolicy.isWebMailHost(host) else { return prefix }
        let stripped = ScreenContextProvider.stripTrailingQuotedBlock(p)
        return stripped == p ? prefix : stripped
    }

    // Generalized leading-context assembly (FR-CTX-1/2/3, FR-PA-3). Prepends, IN ORDER and each gated
    // by isLicensed + its own user toggle:
    //   1. effectiveInstruction (FR-PA-3) — the global/per-app instruction, FIRST (highest steer).
    //   2. styleHint            (FR-CTX-3) — the user's writing-style bias.
    //   3. clipboard            (FR-CTX-2) — current pasteboard text.
    //   4. OCR                  (FR-CTX-1, Free) — recent on-screen text (its own `useScreenOCR` toggle,
    //                                              NOT licence-gated; it is a Free feature).
    // wrapped as `Context:\n<blocks>\n\nText:\n<prefix>` so the base model conditions on the context
    // (see assemblePrompt). The prefix STAYS the forward-from-caret tail (FR-CE-9). Free default
    // (no licence, OCR off) yields exactly `prefix`, so KV reuse + behaviour are unchanged.
    private func assembledPrompt(prefix: String) -> String {
        // Resolve each (already-gated-ready) source, then hand the gating + ordering + join to the pure
        // static below so it is unit-testable without AX/model/overlay (the leak-when-unlicensed property
        // is the security-critical invariant). Style hint is the focus-in snapshot (stable across the
        // burst); OCR is read from its warm cache.
        let instruction = instructionStore?.effectiveInstruction(bundleId: context.frontmostBundleId)
        styleHintLock.lock(); let styleHint = styleHintCache; styleHintLock.unlock()
        let clip = (clipboardContextEnabled && isLicensed)
            ? clipboard?.recentText(maxChars: clipboardContextChars) : nil
        ocrLock.lock(); let ocrRaw = ocrCache; ocrLock.unlock()
        // Strip the user's own draft (and any ghost the OCR captured after it) from the screen text so
        // it isn't duplicated with the prefix below — the draft is only known here, on the prompt path.
        // De-dup the user's own document (already in `prefix`) from the screen text first, then strip
        // the trailing draft line + any ghost OCR captured after it.
        let deDoc = ScreenContextProvider.removingDocumentEcho(ocrRaw, prefix: prefix)
        let deDraft = ScreenContextProvider.removingDraftEcho(deDoc, draft: prefix)
        // Drop email-client quoted-reply chrome ("On <date>, X wrote:" + ">"-lines) ONLY on web-mail
        // hosts. The same prose appears as fresh thread text ABOVE; leaving the quoted copy primes
        // the model to keep quoting. Host-gated: a Markdown blockquote or shell prompt on screen in
        // Slack/GitHub/Terminal must NOT be silently filtered as if it were email chrome.
        let deQuoted = ActivationPolicy.isWebMailHost(context.frontmostDomainHost())
            ? ScreenContextProvider.removingQuotedReplyBlock(deDraft)
            : deDraft
        // After de-duping the user's own doc, keep the screen context only if real prose remains —
        // otherwise it is chrome-only (a sidebar/toolbar) and would just prime garbage, so drop to
        // prefix-only.
        let ocr = ScreenContextProvider.substantialContextOrNil(deQuoted)

        // Language steering (user choice: match the surrounding conversation, else hide). Detect the
        // dominant language of the SAME on-screen context that goes into the prompt (chrome already
        // stripped). Stash it for renderSuggestion's drift suppression, and pass its English name to the
        // assembler so the `Text (in <Language>):` marker steers the base model toward it. nil when
        // there's no confident single-language context → behaviour unchanged.
        // Detect the steer language from the context NEAREST the caret, not the whole capture. Slack and
        // most chat apps expose no AX web-area, so the context is a full-screen OCR dominated by English
        // UI chrome (sidebar, channels, menus); detecting on the whole blob returns English and the
        // Catalan/other-language steer never fires (proven: whole Slack OCR -> en:1.00, the conversation
        // tail -> ca:1.00; the base model then drifts "has trob" -> Spanish "trobado"). The recent
        // messages at the tail carry the reply language. (Never detect from the short prefix — 8 chars of
        // "has trob" misreads as English at 0.95.)
        let ctxLang = (useScreenOCR ? ocr.map { Self.caretLocalContextTail($0) } : nil)
            .flatMap { Self.dominantLanguage($0, minConfidence: 0.70) }
        generationContextLang = ctxLang

        return Self.assemblePrompt(
            prefix: prefix, isLicensed: isLicensed,
            instruction: instruction,
            styleHint: styleHint, styleEnabled: styleProfileEnabled,
            clipboard: clip, clipboardEnabled: clipboardContextEnabled,
            ocr: ocr, ocrEnabled: useScreenOCR,
            steerLanguageName: ctxLang.flatMap(Self.englishLanguageName),
            totalChars: promptCharBudget)
    }

    // English display name for a detected language ("ca" -> "Catalan"), used to steer the base model in
    // the prompt's `Text (in <Language>):` marker. Forced to the en_US locale so the name is the model's
    // expected English form regardless of the user's UI locale. nil if the code has no known name.
    static func englishLanguageName(_ language: NLLanguage) -> String? {
        Locale(identifier: "en_US").localizedString(forLanguageCode: language.rawValue)
    }

    // #8: global character ceiling for the assembled prompt (context blocks + prefix). ~6000 chars
    // ≈1500 tokens — well inside the engine's 4096-token window with generation headroom — so the
    // per-feature caps (OCR/clipboard/style) plus this total guard keep the caret text from being
    // crowded out. The prefix is filled first and never starved.
    private let promptCharBudget = 6000

    // Pure leading-context assembly + GATING (testable: no AX/model/overlay). Prepends, in order:
    //   1. instruction (paid, FR-PA-3)  2. styleHint (paid, FR-CTX-3)  3. clipboard (paid, FR-CTX-2)
    //   4. ocr (FREE, FR-CTX-1 — gated only by its own `ocrEnabled`, NOT by the licence)
    // wrapped as `Context:\n<blocks>\n\nText:\n<prefix>`, the prefix STAYING the forward-from-caret tail
    // (FR-CE-9). The three PAID blocks are
    // dropped whenever `isLicensed` is false (or their toggle is off / value empty), so a Free user can
    // never leak a paid context source. Empty result (no blocks) returns exactly `prefix` (KV reuse safe).
    // `totalChars` is the global character budget for the whole prompt (context blocks + prefix). It
    // defaults to "unbounded" so existing callers/tests keep the exact prior behavior; the live caller
    // passes a finite budget so a noisy screen capture can't crowd out the caret text or blow the
    // context window (#8 PromptSectionBudget). The prefix is given top fill-priority and is never
    // dropped — the lower-priority context blocks (OCR first, then clipboard, style, instruction) trim
    // or drop to fit. Surviving blocks keep their original render order.
    static func assemblePrompt(prefix: String, isLicensed: Bool,
                               instruction: String?,
                               styleHint: String?, styleEnabled: Bool,
                               clipboard: String?, clipboardEnabled: Bool,
                               ocr: String?, ocrEnabled: Bool,
                               steerLanguageName: String? = nil,
                               totalChars: Int = .max) -> String {
        // A base model's tokenizer attaches the leading space to each word (SentencePiece `▁word`), so a
        // prompt ending in a bare space is a "dangling space" the model can't continue cleanly — it
        // degrades into word-salad ("…castillo y que " -> "2 erme en un r es una una…", while the same
        // text WITHOUT the trailing space continues correctly to "tiene un vestido hermoso…"). Trim
        // trailing inline whitespace so the model predicts the next space-prefixed word; on render,
        // reconcileLeadingSpace drops the echoed leading space against the original (untrimmed) prefix.
        let prefix = trimmingTrailingInlineWhitespace(prefix)

        // Build the gated context sections in render order (instruction → style → clipboard → OCR),
        // plus the prefix at top priority so it survives a tight budget. Priorities set the FILL order
        // (prefix first, OCR last); the allocator trims/drops lowest-priority blocks to fit totalChars.
        var sections: [PromptSection] = []
        func addContext(_ s: String?, priority: Int) {
            guard let s, !s.isEmpty else { return }
            // maxChars is a BYTE budget (PromptSectionBudget costs in UTF-8 bytes); each section's own
            // max is its full byte length so it's only trimmed when the TOTAL budget binds.
            sections.append(PromptSection(name: "ctx", content: s, priority: priority,
                                          minChars: 0, maxChars: PromptSectionBudget.cost(s),
                                          truncation: .preserveEnd))
        }
        if isLicensed { addContext(instruction, priority: 80) }              // FR-PA-3 (paid)
        if isLicensed && styleEnabled { addContext(styleHint, priority: 60) } // FR-CTX-3 (paid)
        if isLicensed && clipboardEnabled { addContext(clipboard, priority: 40) } // FR-CTX-2 (paid)
        if ocrEnabled { addContext(ocr, priority: 20) }                     // FR-CTX-1 (FREE)
        // The prefix (kept nearest-the-caret tail) — top priority, never starved.
        let prefixSection = PromptSection(name: "prefix", content: prefix, priority: 1000,
                                          minChars: 0, maxChars: PromptSectionBudget.cost(prefix),
                                          truncation: .preserveEnd)
        sections.append(prefixSection)

        let allocated = PromptSectionBudget.allocate(sections, totalChars: totalChars)
        let outPrefix = allocated.first(where: { $0.name == "prefix" })?.content ?? prefix
        let blocks = allocated.filter { $0.name == "ctx" }.map(\.content)

        guard !blocks.isEmpty else { return outPrefix }
        // Document-shaped framing: a base (pretrained) model follows the `Header:\n…` pattern from its
        // corpus, so labelling the blocks as `Context:` demotes them to reference material and the
        // `Text:` marker tells the model the prefix is the live text to CONTINUE conditioned on that
        // context — instead of reading the whole thing as one flat document whose literal tail it
        // continues (which made "Lighter apple" -> "pie"). Plain words only (no chat/special tokens),
        // and the front stays stable across a typing burst, so the FR-CE-5 KV warm path is intact.
        // Empty-blocks case above still returns the BARE prefix (KV-reuse identity preserved).
        // Language steer: when the context has a confident dominant language, fold its name into the
        // marker (`Text (in Catalan):`) adjacent to the prefix — the strongest cheap lever a base
        // continuation model honors to match the surrounding conversation. nil (default) keeps the bare
        // `Text:` marker, byte-identical to the pre-steer output. The name derives from the cached
        // context, so it's stable across a burst (KV warm path preserved).
        let textMarker = steerLanguageName.map { "\n\nText (in \($0)):\n" } ?? "\n\nText:\n"
        return "Context:\n" + blocks.joined(separator: "\n\n") + textMarker + outPrefix
    }

    // MARK: - Shell-command framing (terminal shell-command mode)

    // Pure (testable): build a few-shot, command-shaped prompt for a base model at a shell prompt. The
    // research-backed lever is FORMAT, not instruction: a block of `$ <command>` lines makes a base model
    // continue the final partial line AS A COMMAND instead of prose. The visible terminal buffer supplies
    // the few-shot exemplars (recent commands), the cwd, and the git branch — all secrets redacted.
    //
    //   # cwd: ~/proj  branch: main          (header, omitted when neither is known)
    //   $ git status                          ┐ recent commands from the buffer (oldest→newest), the
    //   $ npm run build                       ┘ natural few-shot exemplars
    //   $ <typed current-line prefix>         ← the only part that changes per keystroke (no trailing \n)
    //
    // The header + exemplar block is byte-stable across a typing burst at one prompt (only the tail token
    // grows), so the engine's KV warm path (FR-CE-5) is preserved. `prefix` is the forward-from-caret tail;
    // its OWN current line (after the last newline) becomes the typed command — earlier prefix lines are
    // ignored in favour of the richer buffer exemplars.
    static func assembleShellPrompt(prefix: String, terminalBuffer: String?, totalChars: Int = 4000) -> String {
        let typed = trimmingTrailingInlineWhitespace(shellCurrentLine(prefix))
        var lines: [String] = []
        if let header = shellContextHeader(terminalBuffer) { lines.append(header) }
        // Recent commands as few-shot exemplars (redacted). Drop any that equal the typed stem so the model
        // doesn't just echo the line it's completing. Cap so the exemplar block can't crowd the budget.
        let recent = shellRecentCommands(terminalBuffer)
            .map(redactingSecrets)
            .filter { !$0.isEmpty && $0 != typed }
        for cmd in recent.suffix(6) { lines.append("$ " + cmd) }
        // Budget: keep the tail; drop oldest exemplars first if the block is too long.
        var body = lines.joined(separator: "\n")
        while !lines.isEmpty, body.utf8.count + typed.utf8.count + 3 > totalChars {
            // remove the oldest exemplar line (skip the header at index 0 if present)
            let removeAt = (lines.first?.hasPrefix("# ") == true && lines.count > 1) ? 1 : 0
            lines.remove(at: removeAt)
            body = lines.joined(separator: "\n")
        }
        let head = lines.isEmpty ? "" : body + "\n"
        return head + "$ " + typed
    }

    // The current command line being typed: the tail of `prefix` after the last newline.
    static func shellCurrentLine(_ prefix: String) -> String {
        if let nl = prefix.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(prefix[prefix.index(after: nl)...])
        }
        return prefix
    }

    // Pure: pull recent COMMAND text (not output) from the visible buffer — the lines that carry a shell
    // prompt sigil, with the prompt chrome stripped so only the command remains. Oldest→newest order.
    static func shellRecentCommands(_ buffer: String?) -> [String] {
        guard let buffer, !buffer.isEmpty else { return [] }
        var out: [String] = []
        for rawLine in buffer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let cmd = shellCommandAfterSigil(line), !cmd.isEmpty else { continue }
            out.append(cmd)
        }
        return out
    }

    // Given a line, return the command text after a prompt sigil (`…$ git status` -> "git status"), or nil
    // if the line isn't a prompt line. Uses the SAME sigil rule as ActivationPolicy.isShellPromptLine: the
    // last sigil that is followed by a space, with leading `#`/`%` rejected.
    static func shellCommandAfterSigil(_ line: String) -> String? {
        let chars = Array(line)
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            guard ActivationPolicy.shellPromptSigils.contains(chars[i]) else { continue }
            guard i + 1 < chars.count, chars[i + 1] == " " else { continue }
            if (chars[i] == "#" || chars[i] == "%") && i == 0 { continue }
            return String(chars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // Optional `# cwd: …  branch: …` header from cwd / git hints in the buffer. nil when neither is found.
    static func shellContextHeader(_ buffer: String?) -> String? {
        var parts: [String] = []
        if let cwd = shellCwd(buffer) { parts.append("cwd: " + cwd) }
        if let branch = shellGitBranch(buffer) { parts.append("branch: " + branch) }
        return parts.isEmpty ? nil : "# " + parts.joined(separator: "  ")
    }

    // Best-effort cwd from a `user@host:~/path$` style prompt or a literal `pwd` echo in the buffer.
    static func shellCwd(_ buffer: String?) -> String? {
        guard let buffer else { return nil }
        // A path token sitting just before a `$`/`%`/`#` sigil on the LAST prompt line: `…:~/proj$ ` or
        // `host ~/proj %`. Scan the last prompt-bearing line for a `~`- or `/`-rooted path token.
        for rawLine in buffer.split(separator: "\n").reversed() {
            let line = String(rawLine)
            guard shellCommandAfterSigil(line) != nil else { continue }
            // tokens before the sigil
            let tokens = line.split(whereSeparator: { " \t:".contains($0) }).map(String.init)
            if let path = tokens.last(where: { $0.hasPrefix("~") || $0.hasPrefix("/") }) { return path }
            return nil
        }
        return nil
    }

    // Git branch from a starship/oh-my-zsh prompt: a `(branch)` or `on  branch` token on a prompt line.
    static func shellGitBranch(_ buffer: String?) -> String? {
        guard let buffer else { return nil }
        for rawLine in buffer.split(separator: "\n").reversed() {
            let line = String(rawLine)
            guard shellCommandAfterSigil(line) != nil else { continue }
            // `(main)` style
            if let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") {
                let inner = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty, !inner.contains(" ") { return inner }
            }
            return nil
        }
        return nil
    }

    // Pure: redact obvious secrets from a command line before it goes to the model OR is surfaced as a
    // history ghost. Conservative regex-free shape matching on common secret-bearing tokens.
    static func redactingSecrets(_ line: String) -> String {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for i in tokens.indices {
            let t = tokens[i]
            // KEY=value where KEY looks sensitive, or any *_TOKEN / *_SECRET / *_KEY / password.
            if let eq = t.firstIndex(of: "=") {
                let key = String(t[..<eq]).uppercased()
                let sensitive = ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "PWD", "API", "AUTH"]
                if key.hasPrefix("AWS_") || sensitive.contains(where: { key.contains($0) }) {
                    tokens[i] = String(t[..<eq]) + "=•••"
                    continue
                }
            }
            // --password VALUE / --token VALUE → redact the FOLLOWING token.
            let flag = t.lowercased()
            if (flag == "--password" || flag == "--token" || flag == "-p" || flag == "--secret"
                || flag == "--api-key") && i + 1 < tokens.count {
                tokens[i + 1] = "•••"
            }
            // Bearer <value>
            if t == "Bearer", i + 1 < tokens.count { tokens[i + 1] = "•••" }
        }
        return tokens.joined(separator: " ")
    }

    // Remove HTML tags and Markdown emphasis the base model emits from its web-corpus training, so the
    // ghost shows plain continuation text. Pure + idempotent (testable without AX/model):
    //   • `<tag>` / `</tag>` (tag-like: '<' followed by a letter or '/') are dropped entirely.
    //   • A trailing INCOMPLETE tag-like run during streaming (`<stro` before its `>` arrives) is
    //     dropped so it never flashes; it reappears stripped once the closing `>` streams in.
    //   • A bare `<` NOT followed by a letter/'/' (e.g. "a < b", "<3") is kept as a literal.
    //   • `**` is removed; backticks are removed only when UNPAIRED (balanced pairs = inline code, kept).
    static func sanitizedSuggestion(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next.isLetter || next == "/" {                 // tag-like
                    if let close = (i + 1 ..< chars.count).first(where: { chars[$0] == ">" }) {
                        i = close + 1                              // skip the whole `<...>`
                        continue
                    }
                    break                                          // incomplete trailing tag (streaming): drop rest
                }
            }
            // Instruct-template placeholder spans — "[Insert key takeaway here]", "[Your Name]",
            // "[Insertar la información aquí]". The base/instruct models emit these as scaffolding
            // when a prefix reads like a complete sentence or an instruction; they are never useful
            // ghost text. Drop a bracketed span whose content holds a letter (so "[1]"/"[2]" numeric
            // citations survive). An unclosed "[" mid-stream drops the rest, mirroring the tag case.
            if c == "[" {
                if let close = (i + 1 ..< chars.count).first(where: { chars[$0] == "]" }) {
                    if chars[(i + 1) ..< close].contains(where: { $0.isLetter }) {
                        i = close + 1                              // skip the whole `[...]`
                        continue
                    }
                } else if chars[(i + 1) ..< chars.count].contains(where: { $0.isLetter }) {
                    break                                          // incomplete trailing placeholder: drop rest
                }
            }
            out.append(c)
            i += 1
        }
        out = out.replacingOccurrences(of: "**", with: "")
        // Backticks: strip only when UNPAIRED (odd count — a stray markup tick, or the first half of a
        // pair still streaming in). Balanced pairs are inline code the user plausibly wants verbatim
        // ("run `make test`"); blanket-stripping mangled it to "run make test". Still idempotent: an
        // odd count strips to zero, and an even count is left untouched.
        if out.lazy.filter({ $0 == "`" }).count % 2 != 0 {
            out = out.replacingOccurrences(of: "`", with: "")
        }
        out = Self.strippingRuleRuns(out)
        // Strip detokenizer junk (U+FFFD, stray C0 controls/DEL; tab + line feed kept) so a single bad
        // scalar no longer hides the whole completion — the rest of the suggestion still shows (#1).
        return TextSanitizer.removingControlJunk(out)
    }

    // Drop markdown horizontal-rule runs ("---", "***", "___", "===") the instruct model emits as
    // section dividers when it slips into document-authoring mode. Only a run of 3+ identical rule
    // chars is removed, so prose em-dashes ("--") and "===" inside code are mostly untouched; a
    // single leading "- " list marker is handled by strippingLeadingListMarker, not here. Pure.
    static func strippingRuleRuns(_ s: String) -> String {
        let ruleChars: Set<Character> = ["-", "*", "_", "="]
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if ruleChars.contains(c) {
                var j = i
                while j < chars.count, chars[j] == c { j += 1 }
                if j - i >= 3 { i = j; continue }   // skip the whole rule run
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // Strip a SINGLE leading list marker the base model emits when primed by structured screen/OCR
    // context or a rich-text composer (`1. `, `2) `, `- `, `* `, `• `) so the ghost shows the prose
    // continuation, not a list-authoring marker that makes no sense mid-sentence (FR suggestion quality;
    // next iteration of the sanitizedSuggestion markup strip). Pure + idempotent (testable, no AX/model):
    //   • ordered:  ^\s*\d{1,3}[.)]\s+   — needs the trailing space, so "4.5 stars"/"3.14"/"3 PM" are safe.
    //   • bullet:   ^\s*[-*•]\s+
    // At most ONE marker is removed; clean prose passes through untouched.
    static func strippingLeadingListMarker(_ s: String) -> String {
        let chars = Array(s)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }  // leading indent
        if i < chars.count, chars[i] == "-" || chars[i] == "*" || chars[i] == "•" {
            i += 1
        } else {
            var digits = 0
            while i < chars.count, chars[i].isNumber, digits < 3 { i += 1; digits += 1 }
            guard digits > 0, i < chars.count, chars[i] == "." || chars[i] == ")" else { return s }
            i += 1
        }
        // Require at least one whitespace after the marker (true list prefix), then drop it.
        guard i < chars.count, chars[i] == " " || chars[i] == "\t" else { return s }
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return String(chars[i...])
    }

    // True when the suggestion's leading word(s) merely repeat the prefix's trailing word(s)
    // ("thanks for " + "for reading", or "thanks for " + "thanks for reading") — the base model
    // looping back over already-typed text, which injects as a stutter. Compares case-insensitively
    // for k = 1...3 whole words at the boundary. Pure (testable). Conservative: a genuine continuation
    // ("I think " + "we should") shares no boundary words, so it passes.
    static func isPrefixDuplicate(suggestion: String, prefix: String) -> Bool {
        let pWords = prefix.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        let sWords = suggestion.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        guard !pWords.isEmpty, !sWords.isEmpty else { return false }
        let maxK = min(3, pWords.count, sWords.count)
        for k in 1...maxK where Array(pWords.suffix(k)) == Array(sWords.prefix(k)) { return true }
        return false
    }

    // Truncate at the first paragraph break (`\n\n`) that follows real content — the base model's
    // "end then start a new template/list" tell. Leading whitespace is left for the caller's own
    // leading-newline drop; a single `\n` is KEPT (acceptLine still works on a genuine 2nd line).
    // Pure + idempotent (testable).
    static func truncatedAtParagraphBreak(_ s: String) -> String {
        guard let content = s.firstIndex(where: { !$0.isWhitespace }) else { return s }
        if let r = s.range(of: "\n\n", range: content ..< s.endIndex) {
            return String(s[..<r.lowerBound])
        }
        return s
    }

    // Shell-mode display shaping: drop leading newlines, then keep only the FIRST line — a shell
    // completion is exactly one command. Pure (testable).
    static func truncatedAtNewline(_ s: String) -> String {
        let body = s.drop(while: { $0 == "\n" || $0 == "\r" })
        return String(body.prefix(while: { $0 != "\n" && $0 != "\r" }))
    }

    // True when the prefix sits in the gap right after a finished sentence: a trailing whitespace
    // whose last non-space char is sentence-ending punctuation (`. ! ?`). Pure (testable). The
    // no-trailing-space case ("Hello.") never reaches this — isMeaningfulBoundary already rejects it.
    // Decimals ("3.14 ") end on a digit, so they are not blocked.
    static func endsCompleteStatement(_ prefix: String) -> Bool {
        guard let last = prefix.last, last.isWhitespace,
              let lastNonSpace = prefix.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return lastNonSpace == "." || lastNonSpace == "!" || lastNonSpace == "?"
    }

    // True when the suggestion is confidently in a DIFFERENT language than the prefix — the cross-language
    // drift a base model sometimes emits. Deliberately conservative: requires a reasonably long prefix and
    // a HIGH-confidence read on BOTH sides before suppressing, because NLLanguageRecognizer is noisy on
    // short text. Returns false on any ambiguity, so good completions are never collateral. Pure-ish
    // (NaturalLanguage only, no I/O) and testable.
    static func languageDrifts(prefix: String, suggestion: String,
                               minPrefixChars: Int = 40, minConfidence: Double = 0.80) -> Bool {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= minPrefixChars, s.count >= 4 else { return false }
        guard let pl = dominantLanguage(p, minConfidence: minConfidence),
              let sl = dominantLanguage(s, minConfidence: minConfidence) else { return false }
        return pl != sl
    }

    // True when the suggestion is confidently a DIFFERENT language than the surrounding conversation
    // context (whose language the caller already detected). Unlike languageDrifts (which compares against
    // the prefix and needs a long prefix), this keys off the long, high-confidence context language, so it
    // catches a short-prefix drift — a generic Spanish completion in a Catalan thread. Conservative: a
    // short or ambiguous suggestion reads as no-conflict, so good completions are never collateral. Pure
    // (NaturalLanguage only) and testable.
    static func suggestionConflictsWithContext(suggestion: String, contextLang: NLLanguage,
                                               minSuggestionChars: Int = 8,
                                               minConfidence: Double = 0.80) -> Bool {
        let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= minSuggestionChars,
              let sl = dominantLanguage(s, minConfidence: minConfidence) else { return false }
        return sl != contextLang
    }

    // Best-guess language of `text`, but only when the top hypothesis clears `minConfidence`; else nil.
    // The de-chromed context nearest the caret (last few non-empty lines), for LANGUAGE detection only.
    // A full-screen OCR capture is mostly far-away UI chrome whose language (usually English) drowns out
    // the conversation; the recent messages at the tail are the reply language. Pure + testable.
    static func caretLocalContextTail(_ text: String, maxLines: Int = 6, maxChars: Int = 400) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        return tail.count <= maxChars ? tail : String(tail.suffix(maxChars))
    }

    private static func dominantLanguage(_ text: String, minConfidence: Double) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= minConfidence else { return nil }
        return top.key
    }

    // Scripts whose words are space-delimited and whose per-word spell validity is meaningful. CJK/Arabic/
    // Thai etc. are excluded — there "word" and "misspelled" don't map onto a leading letter run.
    private static func isGlueCheckableScript(_ s: String) -> Bool {
        for c in s.unicodeScalars {
            let v = c.value
            let latin = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0xC0 && v <= 0x24F)
            let greek = v >= 0x370 && v <= 0x3FF
            let cyrillic = v >= 0x400 && v <= 0x4FF
            if !(latin || greek || cyrillic) { return false }
        }
        return !s.isEmpty
    }

    // Decide whether the suggestion's leading glue fragment is a SPURIOUS word-extension that should be
    // dropped so the ghost restarts at the next word. Returns the glue run to strip, or nil to keep the
    // suggestion unchanged. Pure + testable: the dictionary is injected as `isValidWord` (no NSSpellChecker).
    // Fires ONLY when the prefix's trailing word is already a valid word but the glued concatenation is not
    // ("pot" valid, "poter" not -> drop "er"). This preserves true mid-word completion (trailing word not yet
    // valid: "develo"+"per") and contractions/compounds (concatenation still valid: "do"+"n't", "pre"+"fix").
    static func spuriousGlue(prefix: String, suggestion: String,
                             isValidWord: (String) -> Bool) -> String? {
        // Prefix must end ON a word char (no trailing space) — that's the boundary where a glue can form.
        guard let plast = prefix.last, plast.isLetter else { return nil }
        // Suggestion must start with a letter (no leading space): a space-led tail is reconcileLeadingSpace's
        // job, and an apostrophe/punct-led tail is the intentional contraction glue we must NOT touch.
        guard let sfirst = suggestion.first, sfirst.isLetter else { return nil }
        // tail = the prefix's trailing letter run; glue = the suggestion's leading letter run.
        let tail = String(prefix.reversed().prefix(while: { $0.isLetter }).reversed())
        let glue = String(suggestion.prefix(while: { $0.isLetter }))
        guard tail.count >= 3, !glue.isEmpty else { return nil }                 // short tails are unstable
        guard isGlueCheckableScript(tail), isGlueCheckableScript(glue) else { return nil }
        // (digits already excluded: letter-only runs by construction.)
        if isValidWord(tail) && !isValidWord(tail + glue) { return glue }
        return nil
    }

    // Impure adapter over spuriousGlue: detect the prefix's language, pin NSSpellChecker to it, and (if the
    // glue is spurious) drop the glue run plus any immediately-following whitespace so reconcileLeadingSpace
    // then adds exactly one separator space. No-ops gracefully when the language is unknown/uninstalled
    // (never breaks a good completion). Memoized per (prefix, glue) so the spell lookups run ~once per gen.
    private func applyGlueGuard(_ suggestion: String, prefix: String) -> String {
        let glueRun = String(suggestion.prefix(while: { $0.isLetter }))
        // Key on (prefix, glue run, suggestion head): prefix + glue run alone collide for two different
        // suggestions whose leading letter run matches (e.g. any two space-leading suggestions share an
        // empty run), so a stable slice of the suggestion itself disambiguates the memo.
        let memoKey = prefix + "\u{0}" + glueRun + "\u{0}" + String(suggestion.prefix(24))
        let drop: String?
        if glueGuardMemoKey == memoKey {
            drop = glueGuardMemoResult
        } else {
            drop = computeSpuriousGlue(suggestion: suggestion, prefix: prefix)
            glueGuardMemoKey = memoKey
            glueGuardMemoResult = drop
        }
        guard let glue = drop else { return suggestion }
        // Drop the glue run + any whitespace that immediately followed it, then re-add exactly ONE leading
        // separator space. Without it the de-glued tail re-glues to the prefix ("pot" + "fer" => "potfer"):
        // reconcileLeadingSpace only normalizes an EXISTING leading space, it never inserts a missing one.
        // Leaving one space here lets reconcileLeadingSpace collapse it correctly against the prefix.
        var rest = Substring(suggestion).dropFirst(glue.count)
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        return rest.isEmpty ? "" : " " + rest
    }

    // The impure half of applyGlueGuard: language detection + NSSpellChecker lookups, fed to the pure decision.
    private func computeSpuriousGlue(suggestion: String, prefix: String) -> String? {
        // Lenient language read (looser than the 40-char/0.80 drift gate) so short prefixes can resolve, but
        // keep a small floor — NLLanguageRecognizer is noise on a handful of chars. Below it, bail (keep).
        guard prefix.count >= 12, let lang = Self.dominantLanguage(prefix, minConfidence: 0.50) else {
            return nil
        }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(lang.rawValue) else { return nil }
        let isValid: (String) -> Bool = { word in
            let r = checker.checkSpelling(of: word, startingAt: 0, language: lang.rawValue,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            return r.location == NSNotFound
        }
        return Self.spuriousGlue(prefix: prefix, suggestion: suggestion, isValidWord: isValid)
    }

    // True when a (sanitized, marker-stripped) suggestion is worthless and should be hidden rather than
    // shown as a ghost: it carries no real word. Kills "1. 1.", "1.", "- -", "•", "1) 2)" — markers/
    // punctuation/single digits the model repeats with no prose. Pure (testable). Any letter => keep (so
    // "but then", "3 days left" pass). Also drops short self-repetition ("the the").
    static func isLowValueSuggestion(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // Letterless: kill marker/punctuation noise, but KEEP real numeric content — a scenario-eval
        // run showed the old blanket "no letter => low value" also ate useful numeric/time/price ghosts
        // ("10:00?" for "quedamos para ", "200.00" after "$1,"). Single-digit list markers stay killed.
        if !trimmed.contains(where: { $0.isLetter }) {
            return !Self.hasMeaningfulNumber(trimmed)
        }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        if tokens.count >= 2, tokens.dropFirst().allSatisfy({ $0 == tokens[0] }), tokens[0].count <= 2 {
            return true  // "the the", short immediate self-repetition
        }
        return false
    }

    // True when a letterless string carries real numeric meaning rather than being list-marker noise:
    // a run of 2+ digits ("200", "10"), a digit-(.,:)-digit group (decimal/thousands/time: "3.14",
    // "10:00"), or a currency-prefixed digit ("$5"). A lone digit with only marker punctuation
    // ("1.", "1) 2)") has none of these, so it stays low-value. Pure + testable.
    static func hasMeaningfulNumber(_ s: String) -> Bool {
        let chars = Array(s)
        for i in chars.indices where chars[i].isNumber {
            if i + 1 < chars.count, chars[i + 1].isNumber { return true }
            if i + 2 < chars.count, chars[i + 1] == "." || chars[i + 1] == "," || chars[i + 1] == ":",
               chars[i + 2].isNumber { return true }
            if i > 0, "$€£¥".contains(chars[i - 1]) { return true }
        }
        return false
    }

    // Reconcile the suggestion's leading whitespace with the prefix so Tab-accept inserts a proper word
    // separator. The model emits a leading space for a new word ("▁should" -> " should"); we keep exactly
    // one when the prefix ends on a word char (so "we" + " should" => "we should", not "weshould"), drop
    // it when the prefix already ends in whitespace (so "we " + " should" => "we should", not a double
    // space), and leave a no-leading-space continuation untouched (a contraction/punctuation tail like
    // "n't" or "," stays glued: "do" + "n't" => "don't"). Pure + testable (no AX/model/overlay).
    static func reconcileLeadingSpace(suggestion: String, prefix: String) -> String {
        guard let f = suggestion.first, f == " " || f == "\t" else { return suggestion }
        let body = String(suggestion.drop(while: { $0 == " " || $0 == "\t" }))
        if let last = prefix.last, last.isWhitespace { return body }   // prefix already separates
        return " " + body                                              // exactly one separator space
    }

    // Strip trailing spaces/tabs (NOT newlines — a newline is an intentional paragraph break the model
    // should continue on a fresh line). Used to avoid feeding the model a dangling-space prompt that
    // degrades base-model output into word-salad. Pure + testable.
    static func trimmingTrailingInlineWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c == " " || c == "\t" { end = prev } else { break }
        }
        return String(s[..<end])
    }

    // Last whitespace-delimited token of `prefix` (FR-CE-6 typo check). Empty if it ends in space.
    static func lastWord(of prefix: String) -> String {
        var idx = prefix.endIndex
        var word = ""
        while idx > prefix.startIndex {
            let prev = prefix.index(before: idx)
            let ch = prefix[prev]
            if ch.isWhitespace { break }
            word.insert(ch, at: word.startIndex)
            idx = prev
        }
        return word
    }

    // MARK: - Generation token helpers

    @discardableResult
    private func bumpGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return gen == generation
    }
}
