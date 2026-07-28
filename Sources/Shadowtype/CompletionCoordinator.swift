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

final class CompletionCoordinator {
    // Confidence-gating thresholds (see ConfidenceGate), expressed in RAW top-1 probability — the
    // model's own softmax peak, not the post-sampler-chain peak these numbers were originally read
    // against. That old number was inflated ~5× (top_k 40 truncation + top_p 0.9 truncate-renormalize +
    // temp 0.4 sharpening), so 0.10/0.08 really meant ~0.02/0.016 on the model's own scale and neither
    // gate ever fired. Re-derived for the raw scale: the first CONTENT token sits at a word boundary,
    // the highest-entropy position in next-token prediction, where a perfectly good continuation
    // routinely peaks at only 0.10–0.25 — so a 0.10 raw floor would eat good suggestions. Below 0.05 the
    // mass is spread over 20+ near-equal candidates: the flat distribution word-salad comes out of. The
    // running mean sits lower (0.03) because it mixes those hard word-start tokens with easy intra-word
    // continuations (often > 0.9), so it only trips on a completion that genuinely came apart — and
    // because a false mean reject truncates a ghost the user may already be reading. Override at runtime
    // via env for live tuning.
    static let firstTokenMinProb: Double =
        envDouble("SHADOWTYPE_GATE_FIRST") ?? 0.05
    static let meanMinProb: Double =
        envDouble("SHADOWTYPE_GATE_MEAN") ?? 0.03

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
    // FR-AC-1: the upgrade to TypoGuard. When the last word looks like a typo and autocorrect is enabled,
    // OFFER a concrete fix (correction ghost) instead of merely
    // suppressing. Pure value type; default-constructed so it is safe even before wiring. nil disables.
    var autocorrect: Autocorrect? = Autocorrect()
    // FR-AC-1 user toggle (paid). Mirrors the OCR/emoji toggle flow: default OFF, persisted in
    // UserDefaults ("GW.autocorrectEnabled"), kept in sync by AppDelegate's didChange observer.
    var autocorrectEnabled: Bool = false
    // FR-CTX-3: on-device encrypted writing-style personalization. Injected (defaults to the
    // shared instance) so M-loop tests can pass a hermetic StyleProfile(storeURL:secret:). Read+written
    // only when styleProfileEnabled.
    var styleProfile: StyleProfile? = StyleProfile.shared
    var styleProfileEnabled: Bool = true
    // FR-CTX-3 Personalization → "strength" (paid, 0...3). Scales the style-hint char budget prepended
    // to the prompt: 0 = off (no hint, even when learning stays on), 1/2/3 = progressively larger bias.
    // Mirrored by AppDelegate.syncToggles; read on focus-in when the hint snapshot is rebuilt.
    var personalizationStrength: Int = 3
    // FR-CTX-2: clipboard-aware context. Synchronous pasteboard read prepended as leading
    // context. Read only when clipboardContextEnabled (default OFF).
    var clipboard: ClipboardContextProvider? = ClipboardContextProvider()
    var clipboardContextEnabled: Bool = false
    // FR-PA-3: custom global + per-app instructions.
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
    // Dominant language of the CACHED screen context, latched once per CAPTURE rather than re-detected on
    // every prompt assembly (#10). Re-detecting per fire let a borderline read flip between two fires of
    // the same typing burst, and that name lands in the `Text (in <Language>):` marker sitting IMMEDIATELY
    // before the prefix — i.e. a change in the prompt head, i.e. a full cold re-prefill on every flip.
    // Recomputed only when storeOCRCache accepts a genuinely different capture. Main-thread only.
    // Text around the caret whose KV warm is waiting on this focus's first OCR capture (#11).
    // warmFocus() defers the prefill rather than warming a prompt the first real fire will not match;
    // the capture's completion flushes it. Carries the post-caret text as well as the prefix for the
    // same reason the deferral exists at all: warming without the `After the cursor:` block the first
    // real fire WILL assemble diverges the two streams inside the context region and throws the whole
    // prefill away. Main-thread only.

    // Per-focus OCR capture lifecycle (main-thread only). `.pending` = the capture for this focus is in
    // flight and we have NO context yet, so fire() holds back the first (context-blind) guess until it
    // lands; `.ready` = the capture completed (even if it found no prose) so prefix-only is allowed.

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
    private static let maxContextRefires = 1

    // Dominant language of the on-screen context fed into the CURRENT generation's prompt (nil when
    // there is no confident single-language context). Set in assembledPrompt, read in renderSuggestion
    // to suppress a completion that drifts to a different language than the surrounding conversation
    // (user choice: match the conversation, else hide). Reset in cancel().

    // Tier 2a: true while the current generation is a mid-word HEAL — the engine regenerated the typed
    // word from a clean boundary and already stripped the reproduced stem, so the ghost text is final.
    // renderSuggestion then skips only the prefix-relative text transforms (reconcile leading space /
    // glue guard / prefix-dup), which assume a fresh continuation and would mangle the healed tail
    // ("at" → " at"). Language safety still applies: a healed wrong-language tail is still wrong.
    // Set per generation in startGeneration. See MidWordHealing / RequiredPrefix.

    // True while the current generation is a TERMINAL shell-command completion (the buffer was a plain
    // shell prompt). renderSuggestion then skips ALL prose transforms (markup strip, list-marker strip,
    // glue/leading-space reconcile, language-drift guards) — every one corrupts shell syntax (backticks =
    // command substitution, `*` = glob, leading `-` = flag) — and instead runs only a newline truncation
    // plus the destructive-command guard. Set per generation in startGeneration / the history fast path.

    // True once the CURRENT generation has actually painted a ghost. renderSuggestion runs per streamed
    // snapshot and its reject filters are evaluated on PARTIAL text, where none of them is monotonic: a
    // two-word intermediate like "the the" satisfies the self-repetition rule, and NLLanguageRecognizer
    // on a 6-character string is a coin flip. Re-running them per snapshot could therefore take a ghost
    // back off screen that the previous snapshot put there — a show → vanish → show flash, precisely the
    // flicker the confidence gate refuses to cause. Once this is set, a reject STOPS further renders
    // instead of retracting (see rejectRender). Reset in bumpGeneration (a superseded generation's ghost
    // is no longer protected) and in clearSuggestion (nothing on screen to protect).

    // Cached writing-style hint (FR-CTX-3). Like the OCR cache, this is refreshed ONLY on focus-in (the
    // cold path), NOT per keystroke: the profile only changes on a Tab-accept, and recomputing it inside
    // assembledPrompt would (a) re-run two O(N log N) sorts over the 400-entry n-gram table on every
    // keystroke and (b) SHIFT the prompt's leading tokens after each accept, busting the FR-CE-5 warm KV
    // cache on the next keystroke. Snapshotting it per focus-in keeps the leading block stable during a
    // typing burst (warm) and moves the sort off the hot path.
    private let contextAssembler = CompletionContextAssembler()

    // True while a selection-rewrite is generating or its preview HUD is up (set by AppDelegate). The
    // keystroke hot path stays quiet during it so the ghost loop doesn't fight the rewrite UI.
    var rewriteActive = false

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
    // INTEGRATOR-OWNED: settable so AppDelegate can drive it from CompletionLength.current at launch
    // and on every length-preference change (FR-CE-3). The coordinator never reads CompletionLength
    // itself — AppDelegate
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

    private let generationSession = CompletionGenerationSession()
    // Memo for applyGlueGuard: renderSuggestion runs on every streamed token snapshot, but for a fixed
    // prefix the trailing word and the suggestion's leading glue run are stable — so the language detect
    // + two spell lookups should run once per generation, not per token. Keyed on (prefix, glue run,
    // first 24 chars of the suggestion) — the suggestion slice disambiguates two different suggestions
    // that share a prefix + leading-letter run (e.g. both space-leading).
    private var glueGuardMemoKey: String?
    private var glueGuardMemoResult: String?
    private lazy var ghostPresentation = GhostPresentationController(overlay: overlay)
    private var suggestionVisible: Bool {
        get { ghostPresentation.isVisible }
        set {
            ghostPresentation.setVisible(newValue) { visible in
                onSuggestionVisibleChanged?(visible)
                if visible {
                    onCaretAtLineEndChanged?(context.caretAtLineEnd())
                    startFontWatch()
                } else {
                    onCaretAtLineEndChanged?(false)
                    stopFontWatch()
                }
            }
        }
    }
    // The ONE focus resolution for the current fire() (#9). Every gate in fire() and the render path
    // reads AX facts from here instead of re-walking the tree. Dropped in cancel(); `currentFocusSnapshot`
    // additionally refuses to hand back a snapshot whose focus session has since changed, so a stale
    // snapshot can never cross a focus change.
    private var focusSnapshot: EditContextTracker.FocusSnapshot?
    private var currentFocusSnapshot: EditContextTracker.FocusSnapshot? {
        guard let s = focusSnapshot, s.focusSeq == context.focusChangeSequence else { return nil }
        return s
    }
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
        contextAssembler.refireCount = 0     // a new keystroke/focus/force re-arms the one context-upgrade re-fire
        generationSession.contextLanguage = nil
        // #9: the focus resolution belongs to the superseded fire(). Dropping it here (plus the focus-seq
        // check in `currentFocusSnapshot`) is what guarantees a stale snapshot can never cross into
        // another field — cancel() runs on every keystroke, focus change and force-activate.
        focusSnapshot = nil
        // #11: a warm prefill deferred behind a capture is for the field we are leaving.
        contextAssembler.pendingWarm = nil
        clearSuggestion()
    }

    // Same-app focus moves do not emit an NSWorkspace activation notification. AppDelegate calls this
    // from EditContextTracker.onFocusChange so the old field's decode, ghost, and OCR context are all
    // invalidated before the new field is warmed.
    func focusDidChange() {
        cancel()
        screenContext?.focusDidChange()
        storeOCRCache(nil)
        contextAssembler.captureState = .idle
        contextAssembler.pendingWarm = nil
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
        // Count the request as ACTIVITY before anything else. The idle-unload timer only ever saw
        // keyboard/focus events, so `unloadModelIfIdle` would free the model out from under a client
        // that had been streaming for ten minutes, and once unloaded every later request died at the
        // `engine.isLoaded` guard below — forever, until the user physically typed somewhere. The
        // in-flight count additionally lets AppDelegate refuse to unload while a decode is running.
        noteAPIRequestStarted()
        inferenceQueue.async { [weak self] in
            // Review #5: route handlers block on a DispatchSemaphore waiting for onComplete to
            // fire — if we early-return without invoking it (coordinator deallocated during
            // teardown), the HTTP worker hangs forever and leaks the socket. Always call
            // onComplete on EVERY exit path so the route writes a response and closes.
            guard let self else {
                // No self means the coordinator (and with it the counter nobody can read any more) is
                // gone; just make sure the waiting route is released.
                onComplete(.failure(.modelNotLoaded))
                return
            }
            defer { self.noteAPIRequestFinished() }
            guard self.engine.isLoaded else { onComplete(.failure(.modelNotLoaded)); return }
            do {
                try self.engine.generate(prompt: prompt,
                                         maxTokens: maxTokens,
                                         seqID: 1,
                                         params: params,
                                         contextTokenCap: self.engine.contextWindowTokens,
                                         requiredPrefix: nil,
                                         onToken: { piece in
                                             if cancelToken.isCancelled { return false }
                                             return onPiece(piece)
                                         },
                                         onSample: nil)
                // Hand seq 1's cells straight back, exactly as the rewrite path does for seq 2:
                // `kv_unified` means every seq draws from ONE n_ctx-sized pool, and an API prompt is
                // never reused as a ghost prefix, so holding these cells only starves the ghost — after
                // sizeable API use the ghost's own prefill could no longer find a KV slot.
                self.engine.releaseSeq(1)
                onComplete(.success(()))
            } catch {
                self.engine.releaseSeq(1)
                onComplete(.failure(.decodeFailed(error)))
            }
        }
    }

    // MARK: - API activity + liveness (idle-unload interlock)

    private let apiActivityLock = NSLock()
    private var apiRequestsInFlight = 0

    // True while at least one API/MCP generation is queued or decoding. AppDelegate's idle-unload timer
    // consults this so it can't tear the model down mid-stream.
    var hasInFlightAPIRequests: Bool {
        apiActivityLock.lock(); defer { apiActivityLock.unlock() }
        return apiRequestsInFlight > 0
    }

    // Fired on MAIN whenever an API/MCP request arrives. AppDelegate wires this to the same
    // "note activity, and lazily reload if the idle timer unloaded the model" path the keystroke and
    // focus handlers use — the only thing that could previously wake an idle-unloaded engine.
    var onExternalActivity: (() -> Void)?

    private func noteAPIRequestStarted() {
        apiActivityLock.lock(); apiRequestsInFlight += 1; apiActivityLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onExternalActivity?() }
    }

    private func noteAPIRequestFinished() {
        apiActivityLock.lock()
        apiRequestsInFlight = max(0, apiRequestsInFlight - 1)
        apiActivityLock.unlock()
    }

    // The context window an API/MCP request actually gets, for /v1/health to advertise honestly. The
    // ghost's `maxContextTokens` is the USER's small "Context window size" setting and must not be
    // reported as the server's capability.
    var apiContextTokens: Int { engine.contextWindowTokens }

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

    // MARK: - Selection rewrite (local)

    // Run the on-device model to rewrite `selection` per `action`, delivering the cleaned result on the
    // main queue (nil = unavailable / empty output). Reuses the single engine on the serial
    // inferenceQueue with the same newest-wins
    // bumpGeneration discipline as ghost generation: it cancels any running decode so its prompt gets the
    // queue promptly, and is itself superseded (returns nothing) if the user triggers again. Unlike the
    // ghost path this is a ONE-SHOT instruction-style few-shot prompt (RewriteAction), so the KV cache
    // resets to a cold prefill — acceptable for an explicit, occasional action.
    //
    // It runs on its OWN sequence (2), never the ghost's seq 0. The few-shot prompt diverges from the
    // ghost stream at token 0, so the engine's reuseLength() returns 0 and it resets the seq — on seq 0
    // that dropped the ENTIRE ghost prefix, making the first keystroke after every rewrite pay a second
    // full cold prefill. Seq 1 is the API/MCP slot (see runRawCompletion), so rewrite takes 2; the
    // engine's n_seq_max is 4 and kv_unified means the seqs share one n_ctx pool rather than carving it up.
    func rewrite(selection: String, action: RewriteAction, completion: @escaping (String?) -> Void) {
        guard engine.isLoaded, !selection.isEmpty else { completion(nil); return }
        let tone = instructionStore?.effectiveInstruction(bundleId: context.frontmostBundleId)
        // Steer the base model to the SELECTION's language. The exemplar is English; without an explicit
        // marker the model mirrors it and emits English regardless of what the user selected. Confidence
        // threshold matches languageDrifts (0.50) — selections are user-curated, lower noise than OCR.
        let declared = UserDefaults.standard.string(forKey: Self.personalizeLanguagesKey) ?? ""
        let languageConstraints = Self.parsePersonalizedLanguages(declared)
        let lang = Self.dominantLanguage(selection, minConfidence: 0.50,
                                         languageConstraints: languageConstraints)
            .flatMap(Self.englishLanguageName)
        let prompt = RewriteAction.prompt(for: action, selection: selection, userTone: tone, language: lang)
        let budget = RewriteAction.maxTokens(forSelection: selection)
        // Ghost sampling minus the ghost stop policy, plus a fresh seed per call so ⌘R redo actually
        // re-rolls instead of replaying the same text (see SamplingParams.rewriteDefaults).
        let params = SamplingParams.rewriteDefaults()
        let myGen = bumpGeneration()
        engine.requestCancel()     // stop a running ghost decode so the serial queue frees up promptly
        Diag.log("rewrite: action=\(action.rawValue) selLen=\(selection.count) budget=\(budget) lang=\(lang ?? "auto")")
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            var acc = ""
            do {
                try self.engine.generate(prompt: prompt, maxTokens: budget, seqID: 2, params: params,
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
            // Hand seq 2's cells straight back: `kv_unified` shares one n_ctx pool, and a rewrite prompt
            // always diverges at token 0, so this cache can never be reused — holding it would just starve
            // the ghost (ghost + rewrite both near the cap exceed the pool and llama_decode fails).
            self.engine.releaseSeq(2)
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

        // #9: ONE AX resolution per fire, handed to every gate below. Each gate used to re-read the
        // systemwide focused element and re-run the descendToEditable BFS (visitCap 64) for itself; a
        // diag from a real machine caught the tree being walked ~14 times in 130 ms, every walk
        // returning prefix: nil. nil here means nothing is focused — the gates below then see exactly
        // what they saw before (isSecure false, no marked text, no host, prefix nil), so the
        // capability-flicker gate and the AX-nudge branch still run.
        let snapshot = context.resolveFocusSnapshot()
        focusSnapshot = snapshot
        let host = snapshot?.domainHost

        // FR-KC-4 / disabled-app+domain gate: never suggest in a secure field or a suppressed
        // app/domain (FR-PA-1/2). AppRules default is on everywhere; nil rules == on everywhere.
        if snapshot?.isSecure == true { Diag.log("fire: skip secureField"); clearSuggestion(); return }
        // IME composition guard: while marked (preedit) text is live — CJK composition — never fire,
        // and clear any visible ghost (it overlaps the candidate window and an accept would splice into
        // the composition buffer). Best-effort single AX read; hosts that don't expose AXMarkedTextRange
        // return false and behave exactly as before (see EditContextTracker.hasMarkedText).
        if let snapshot, context.hasMarkedText(in: snapshot) {
            Diag.log("fire: skip markedText (IME composing)"); clearSuggestion(); return
        }
        if let appRules, !appRules.isEnabled(bundleId: context.frontmostBundleId, domain: host) {
            Diag.log("fire: skip disabledApp/domain \(context.frontmostBundleId ?? "?")"); clearSuggestion(); return
        }

        // Read the terminal's visible buffer ONCE per keystroke and reuse it for both the idle gate and
        // the shell-mode decision below (an AX value read is an IPC round-trip; doing it twice per
        // keystroke is wasteful). nil for non-terminals, so ordinary apps pay nothing.
        let shellBuffer = ActivationPolicy.isTerminal(bundleId: context.frontmostBundleId)
            ? context.focusedElementText() : nil

        // FR-CE-9: prefix-before-caret ONLY. nil => no editable focus. Read once and run it through the
        // capability-flicker gate (#3): a single nil read on the SAME focus session is usually a
        // transient republish (Catalyst fields drop their value mid-redraw), so hold the current ghost
        // instead of tearing it down. A genuine focus change (different session) or a sustained miss
        // still propagates to the teardown below.
        // On web-mail hosts, the caret may sit BELOW the quoted-reply block (Gmail's "Show trimmed
        // content" reveal); the raw prefix then ends with "On <date>, X wrote:" + ">"-lines and the
        // ghost would just continue the quoted prose. Strip the trailing quoted block so the prompt
        // sees the user's actual new prose (often empty → bail cleanly).
        let originalPrefix = snapshot?.prefix
        let rawPrefix = Self.prefixAfterEmailQuoteStrip(originalPrefix, host: host)
        let bundleId = context.frontmostBundleId
        let managed = !forced && ActivationPolicy.isManaged(bundleId: bundleId)
        let heights = managed && ActivationPolicy.isEditor(bundleId: bundleId)
            ? context.focusedFieldAndWindowHeights() : nil
        let shellOptIn = managed && ActivationPolicy.isTerminal(bundleId: bundleId)
            && appSettings.resolve(\.shellCommands, forBundleId: bundleId, globalDefault: false)
        let prefixEvaluation = CompletionActivationEvaluator.evaluatePrefix(
            .init(
                forced: forced,
                bundleId: bundleId,
                terminalText: shellBuffer,
                editorFieldHeight: heights?.field,
                editorWindowHeight: heights?.window,
                shellCommandsEnabled: shellOptIn,
                originalPrefix: originalPrefix,
                prefix: rawPrefix,
                focusSeq: context.focusChangeSequence,
                emojiTrigger: rawPrefix.map(isEmojiTrigger) ?? false,
                minPrefixChars: minPrefixChars
            ),
            capabilityGate: capabilityGate
        )
        capabilityGate = prefixEvaluation.capabilityGate

        let prefix: String
        let shellMode: Bool
        switch prefixEvaluation.decision {
        case let .holdCapability(misses):
            Diag.log("fire: hold (capability flicker, miss \(misses))")
            return
        case .skip(.idleContext):
            Diag.log("fire: skip idleContext \(bundleId ?? "?")")
            clearSuggestion()
            return
        case .skip(.missingPrefix):
            let cause = (originalPrefix?.isEmpty == false) ? "quoted-strip consumed all" : "AX gave no text-before-caret"
            Diag.log("fire: skip prefix=nil/empty (app=\(bundleId ?? "?")) — \(cause)")
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
            clearSuggestion()
            return
        case .skip(.notBoundary):
            Diag.log("fire: skip notBoundary")
            Diag.logContent("fire: skip notBoundary prefixTail=\"\(String((rawPrefix ?? "").suffix(12)))\"")
            clearSuggestion()
            return
        case .skip(.thinContext):
            Diag.log("fire: skip thinContext")
            Diag.logContent("fire: skip thinContext prefixTail=\"\(String((rawPrefix ?? "").suffix(12)))\"")
            clearSuggestion()
            return
        case .skip(.completeStatement):
            Diag.log("fire: skip completeStatement")
            clearSuggestion()
            return
        case let .continueEvaluation(evaluatedPrefix, evaluatedShellMode):
            prefix = evaluatedPrefix
            shellMode = evaluatedShellMode
        case .skip:
            clearSuggestion()
            return
        }

        guard let resolvedSnapshot = snapshot else {
            clearSuggestion()
            return
        }
        let midLineEnabled = appSettings.resolve(
            \.midLine, forBundleId: bundleId, globalDefault: false
        )
        let nonProseField = !forced && context.focusedFieldIsNonProse(in: resolvedSnapshot)
        let caretAtLineEnd = midLineEnabled || context.caretAtLineEnd(in: resolvedSnapshot)
        let preTypoSnapshot = CompletionActivationEvaluator.Snapshot(
            prefix: prefix,
            shellMode: shellMode,
            terminalText: shellBuffer,
            nonProseField: nonProseField,
            midLineEnabled: midLineEnabled,
            caretAtLineEnd: caretAtLineEnd,
            emojiEnabled: emojiEnabled,
            emoji: emoji,
            typo: .notLikely,
            holdBackOnTypos: holdBackOnTypos,
            contextCapturePendingWithoutContext: false
        )
        switch CompletionActivationEvaluator.evaluateBeforeTypo(preTypoSnapshot) {
        case .skip(.nonProseField):
            Diag.log("fire: skip nonProseField \(bundleId ?? "?")")
            clearSuggestion()
            return
        case .skip(.midLineDisabled):
            Diag.log("fire: skip midLineOff \(bundleId ?? "?")")
            clearSuggestion()
            return
        case let .emoji(value, queryLength):
            Diag.logContent("fire: emoji match -> \(value)")
            showEmoji(value, queryLength: queryLength)
            return
        case .continueEvaluation:
            break
        case .skip:
            clearSuggestion()
            return
        }

        let typoAssessment = CompletionActivationEvaluator.assessTypo(
            prefix: prefix,
            typoGuard: typoGuard,
            autocorrectEnabled: appSettings.resolve(
                \.autocorrect, forBundleId: bundleId, globalDefault: autocorrectEnabled
            ),
            autocorrect: autocorrect
        )
        let action = CompletionActivationEvaluator.evaluateAfterTypo(
            .init(
                prefix: prefix,
                shellMode: shellMode,
                terminalText: shellBuffer,
                nonProseField: nonProseField,
                midLineEnabled: midLineEnabled,
                caretAtLineEnd: caretAtLineEnd,
                emojiEnabled: emojiEnabled,
                emoji: emoji,
                typo: typoAssessment,
                holdBackOnTypos: holdBackOnTypos,
                contextCapturePendingWithoutContext: false
            )
        )
        switch action {
        case .skip(.typo):
            let lastWord = Self.lastWord(of: prefix)
            Diag.log("fire: skip typo")
            Diag.logContent("fire: skip typo lastWord=\"\(lastWord)\"")
            clearSuggestion()
            return
        case let .correction(value, run):
            Diag.log("fire: autocorrect offer")
            Diag.logContent("fire: autocorrect \"\(run)\" -> \"\(value)\"")
            showCorrection(value, run: run)
            return
        case let .shellHistory(remainder):
            Diag.log("fire: shell history match -> render (no model)")
            showShellHistory(prefix: prefix, remainder: remainder)
            return
        case .generate:
            break
        case .emoji:
            clearSuggestion()
            return
        case .skip:
            clearSuggestion()
            return
        }

        // FR-CTX-1: keep the OCR context fresh for the CURRENT viewport. Re-capturing on this pause (not
        // just focus-in) reflects scrolling and late captures; the provider's ≤1/s throttle + the
        // storeOCRCache change-guard keep KV warm when the visible text hasn't changed.
        if useScreenOCR, !shellMode {
            refreshOCRContextIfEnabled(prefix: prefix, snapshot: resolvedSnapshot)
            // Don't paint a context-blind guess while this focus's first capture is still in flight — its
            // completion re-fires with real context. Only suppress when we have NOTHING yet (.pending, no
            // cache); a completed-but-empty capture (.ready) falls through to prefix-only.
            let haveOCR = contextAssembler.cachedOCR != nil
            if !haveOCR, contextAssembler.captureState == .pending {
                Diag.log("fire: defer (OCR capture pending, no context yet)")
                clearSuggestion(); return
            }
        }

        // Post-caret conditioning: hand the model the text that FOLLOWS the caret so it stops writing
        // sentences that duplicate or contradict the paragraph below (see postCaretBlock). Comes free
        // from the snapshot — the same single AX read that produced the prefix — and is nil on the
        // web/text-marker hosts, which can't see past the caret. Off in shell mode: the terminal buffer
        // IS the context there, and assembleShellPrompt doesn't take context blocks at all.
        let postCaret = shellMode ? nil : resolvedSnapshot.suffix
        Diag.log("fire: START gen len=\(prefix.count) post=\(postCaret?.count ?? -1)\(shellMode ? " [shell]" : "")")
        Diag.logContent("fire: START gen prefixTail=\"\(String(prefix.suffix(24)))\"")
        startGeneration(prefix: prefix, postCaret: postCaret,
                        shellMode: shellMode, terminalBuffer: shellBuffer)
    }

    // Render a history-derived shell completion verbatim, bypassing the model. Mirrors how
    // startGeneration seeds the per-generation flags so renderSuggestion takes the shell-mode branch
    // (Tab then injects `ghostPresentation.suggestionText`, exactly like a model completion).
    private func showShellHistory(prefix: String, remainder: String) {
        bumpGeneration()                       // supersede any in-flight model run
        generationSession.activePrefix = prefix
        generationSession.focusSeq = context.focusChangeSequence
        generationSession.rtl = false
        generationSession.isHealed = false
        generationSession.contextLanguage = nil
        generationSession.shellMode = true
        // This ghost never goes through startGeneration, so it has no hoisted geometry/language of its
        // own — clear any left over from the superseded generation and let renderSuggestion read live.
        generationSession.caretRect = nil
        generationSession.font = nil
        generationSession.prefixLanguage = nil
        generationSession.languageConstraints = []
        renderSuggestion(remainder)
    }

    // Cheap pure predicate: is the prefix currently inside an emoji `:shortcode`? Used only as the
    // boundary-gate bypass above, so the emoji ghost keeps firing on a shortcode that ends on a
    // non-word character (`:thumbs_`, `:+`). Never consults AX or the model.
    private func isEmojiTrigger(_ prefix: String) -> Bool {
        guard emojiEnabled, let emoji else { return false }
        return emoji.isTrigger(prefix: prefix)
    }

    // MARK: - Generation (newest-wins, deadline-drop)

    // `postCaret` is the text following the caret for THIS fire (nil when the host's AX read can't see
    // past the caret, when nothing follows it, or in shell mode). It only reaches the prompt — never the
    // ghost — see assembledPrompt / postCaretBlock.
    func startGeneration(prefix: String, postCaret: String? = nil,
                         shellMode: Bool = false, terminalBuffer: String? = nil) {
        let myGen = bumpGeneration()
        generationSession.activePrefix = prefix
        generationSession.focusSeq = currentFocusSnapshot?.focusSeq ?? context.focusChangeSequence
        generationSession.shellMode = shellMode
        generationSession.rtl = TextDirectionDetector.isRightToLeft(prefix)   // #14: once per generation, not per token
        glueGuardMemoKey = nil; glueGuardMemoResult = nil   // fresh prefix -> recompute the glue decision
        // #9: everything else that is a pure function of the (now fixed) prefix or of a caret the paused
        // user is not moving. Each of these ran on EVERY ~33 ms render tick: a full
        // NLLanguageRecognizer pass over the whole prefix, plus an AX caret-rect and an AX caret-font
        // round trip per frame.
        let declared = UserDefaults.standard.string(forKey: Self.personalizeLanguagesKey) ?? ""
        generationSession.languageConstraints = Self.parsePersonalizedLanguages(declared)
        generationSession.prefixLanguage = Self.driftPrefixLanguage(
            prefix, languageConstraints: generationSession.languageConstraints)
        let caret = currentFocusSnapshot.flatMap { context.caretRectOnScreen(in: $0) }
            ?? context.caretRectOnScreen()
        generationSession.caretRect = caret
        generationSession.font = hostFont(caretHeight: (caret ?? .null).height)

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
        let deadlineWork = generationSession.makeDeadlineWork(
            generation: myGen,
            firstTokenSeen: { firstTokenSeen }
        ) { [weak self] in
            guard let self else { return }
            self.bumpGeneration()          // supersede the slow run
            self.engine.requestCancel()
            if Self.shouldPreserveHeldSuggestion(
                isRefire: self.generationSession.inContextRefire,
                visible: self.suggestionVisible,
                text: self.ghostPresentation.suggestionText) {
                self.generationSession.inContextRefire = false
                self.generationSession.clearPendingStream()
                Diag.log("gen: deadline expired -> kept held ghost")
            } else {
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
        generationSession.isHealed = (requiredPrefix != nil)

        // FR-CTX-1/2/3, FR-PA-3: assemble enabled leading context, then the user's prefix as the
        // forward-from-caret tail. With context toggles off, effectivePrompt is the
        // prefix (anchor-windowed once it outgrows the budget), so KV reuse holds across a typing burst.
        // Shell mode swaps in the few-shot `$ command` framing
        // built from the terminal buffer (the OCR/style/clipboard context blocks don't apply there).
        let preparedPrompt = shellMode
            ? CompletionContextAssembler.PreparedPrompt(
                prompt: Self.assembleShellPrompt(
                    prefix: promptPrefix,
                    terminalBuffer: terminalBuffer
                ),
                byteBudget: nil,
                cacheKey: nil
            )
            : tokenizerBudgetedPrompt(prefix: promptPrefix, postCaret: postCaret)
        var effectivePrompt = preparedPrompt.prompt
        var effectivePromptByteBudget = preparedPrompt.byteBudget
        // Command-shaped sampling for shell mode: deterministic (temp 0.2), single line (stop at "\n",
        // useEngineStopPolicy=false → raw stream, no prose word/sentence caps). Same seq 0 for KV continuity.
        let genParams: SamplingParams = shellMode ? .commandDefaults : .ghostDefaults
        let genMaxTokens = shellMode ? Self.shellMaxTokens : self.maxTokens

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            // The request may expire or lose focus while queued behind another serial decode. Reject it
            // before prefill so stale work cannot monopolize inference after its UI generation is dead.
            guard self.isCurrent(myGen) else { return }
            var acc = ""
            while true {
                do {
                    try self.engine.generate(prompt: effectivePrompt, maxTokens: genMaxTokens,
                                             seqID: 0, params: genParams,
                                             contextTokenCap: shellMode ? nil : self.engine.maxContextTokens,
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
                    // Running mean gate — the word-salad backstop. It used to be evaluated only AFTER the
                    // whole decode and then refused to hide anything already on screen; since the first
                    // content token renders synchronously and unconditionally, "already on screen" was
                    // every path that had text to reject, so the branch was structurally unreachable and
                    // the backstop had never fired once. Checked per token instead. `gate` already
                    // includes THIS token (the engine calls onSample before onToken), so returning false
                    // here drops the flailing token and everything after it, leaving the ghost rendered
                    // up to the previous token exactly as it is.
                    // TRADEOFF (deliberate): this SHORTENS a collapsing completion rather than
                    // suppressing it. The two alternatives each break a harder rule — retracting the
                    // visible ghost is the show→vanish flicker this file refuses to cause anywhere else,
                    // and withholding the first render for a few tokens costs first-appearance latency,
                    // which is the product. Cutting at the collapse point costs neither, and with the
                    // first-token gate now working on real probabilities it is the cheap half of the job.
                    if gate.meanRejected {
                        Diag.log("gen: mean confidence collapsed mean=\(gate.meanProbString) -> stop (kept rendered ghost)")
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
                        if self.generationSession.inContextRefire {
                            switch self.ghostPresentation.refireDecision(for: snapshot) {
                            case .hold, .discard:
                                return
                            case .renderExtension:
                                break    // fall through to the render path; keep generationSession.inContextRefire true
                            }
                        }
                        // First token renders immediately so the ghost appears without delay; subsequent
                        // tokens are coalesced to ≤1 render per ~33 ms, killing per-token re-anchor
                        // jitter on fast local models without delaying the perceived first-appearance.
                        if isFirst {
                            self.generationSession.clearPendingStream()
                            self.renderSuggestion(snapshot)
                            return
                        }
                        self.generationSession.coalesce(
                            snapshot: snapshot,
                            generation: myGen
                        ) { [weak self] pending in
                            self?.renderSuggestion(pending)
                        }
                    }
                        return !halt
                    }, onSample: { prob, isFirst in
                        gate.record(prob: Double(prob), isFirst: isFirst)
                    })
                    if let key = preparedPrompt.cacheKey,
                       let budget = effectivePromptByteBudget {
                        self.storeTokenizerValidatedBudget(budget, for: key)
                    }
                    break
                } catch InferenceError.contextOverflow(let tokenCount, let tokenCap) {
                    guard !shellMode, self.isCurrent(myGen),
                          let currentBudget = effectivePromptByteBudget,
                          let nextBudget = PromptSectionBudget.nextByteBudget(
                            current: currentBudget, tokenCount: tokenCount, tokenCap: tokenCap)
                    else {
                        NSLog("Shadowtype: generate failed: prompt tokenizer overflow")
                        Diag.log("gen: ERROR tokenizer overflow tokens=\(tokenCount) cap=\(tokenCap)")
                        break
                    }
                    effectivePromptByteBudget = nextBudget
                    if let key = preparedPrompt.cacheKey, key.tokenCap == tokenCap {
                        self.storeTokenizerValidatedBudget(nextBudget, for: key)
                    }
                    let rebuilt: String? = DispatchQueue.main.sync {
                        guard self.isCurrent(myGen) else { return nil }
                        return self.assembledPrompt(prefix: promptPrefix, postCaret: postCaret,
                                                    totalChars: nextBudget)
                    }
                    guard let rebuilt else { break }
                    effectivePrompt = rebuilt
                    Diag.log("gen: tokenizer re-budget \(tokenCount)>\(tokenCap), bytes=\(nextBudget)")
                } catch {
                    NSLog("Shadowtype: generate failed: \(error)")
                    Diag.log("gen: ERROR \(error)")
                    break
                }
            }
            let finalGate = gate
            DispatchQueue.main.async {
                deadlineWork.cancel()
                // Flush any token coalesced for the next ~33 ms — generation is done, no point waiting.
                // During a held re-fire we honour the same monotonic rule the per-token branch uses:
                // commit only if the coalesced snapshot strictly extends the visible ghost; hold or
                // discard otherwise. (Outside a re-fire, render normally as before.)
                if let s = self.generationSession.takePendingStream() {
                    if self.isCurrent(myGen) {
                        if self.generationSession.inContextRefire {
                            if case .renderExtension = self.ghostPresentation.refireDecision(for: s) {
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
                let heldRefire = self.generationSession.inContextRefire
                self.generationSession.inContextRefire = false
                if heldRefire, self.isCurrent(myGen), !acc.isEmpty {
                    if case .renderExtension = self.ghostPresentation.refireDecision(for: acc) {
                        self.renderSuggestion(acc)
                    } else {
                        Diag.log("gen: refire divergent -> discard (kept visible ghost)")
                    }
                }
                // No post-decode confidence check here on purpose: the cumulative mean gate that used to
                // live at this point could only ever hide a ghost that had NOT been committed to screen,
                // and by the time this runs the first-token render always has — it was dead code. The
                // mean gate now runs per token inside onToken above, where it can still stop the decode.
                // If the stream produced nothing and is still current, hide.
                if self.isCurrent(myGen) && acc.isEmpty {
                    Diag.log("gen: produced nothing (deadline/EOG)")
                    if !Self.shouldPreserveHeldSuggestion(
                        isRefire: heldRefire,
                        visible: self.suggestionVisible,
                        text: self.ghostPresentation.suggestionText) {
                        self.clearSuggestion()
                    }
                } else if self.isCurrent(myGen) {
                    Diag.log("gen: done len=\(acc.count) mean=\(finalGate.meanProbString)")
                    Diag.logContent("gen: done acc=\"\(acc.prefix(40))\"")
                }
                if self.isCurrent(myGen), !heldRefire {
                    self.maybeNoteSmartComposeOverlap(forGeneration: myGen)
                }
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
        if useScreenOCR {
            screenContext?.focusDidChange()
            storeOCRCache(nil)
            contextAssembler.captureState = .idle
        }
        contextAssembler.pendingWarm = nil

        guard let prefix = context.currentPrefix(), !prefix.isEmpty else { return }
        // Same post-caret text the first real fire will assemble into the prompt (see postCaretBlock).
        // Read here rather than left nil because a warm prefill that omits a block the first fire
        // includes diverges from it and is discarded — the #11 failure this whole deferral exists for.
        // Costs one extra AX read per FOCUS (not per keystroke), and it is served from the same
        // value+range the prefix read already resolved.
        let postCaret = context.suffixAfterCaret()

        // FR-CTX-1 (gated, default OFF): kick the on-screen OCR capture for this focus. fire() re-captures
        // on each typing pause too (so scrolling is reflected); storeOCRCache's change-guard keeps the
        // prepended OCR block — and thus the KV cache — stable while the visible text is unchanged.
        refreshOCRContextIfEnabled(prefix: prefix)
        // FR-CTX-3: snapshot the style hint on focus-in too, so it stays stable through the typing burst
        // (warm KV) and its sort stays off the per-keystroke path.
        refreshStyleHintIfEnabled()

        // #11: the OCR branch of refreshOCRContextIfEnabled is ASYNCHRONOUS — it returns with `contextAssembler.cachedOCR`
        // still nil and lands the capture milliseconds later. Warming here anyway (what this used to do,
        // under a comment claiming it assembled "exactly as startGeneration does") prefilled
        // `Text:\n<prefix>` while the first real fire assembles `Context:\n<ocr>…Text:\n<prefix>`: the two
        // streams diverge at token 0, so the ENTIRE warm prefill was discarded — and, because it ran on
        // the serial inferenceQueue, the first real generation then queued behind a cold prefill it could
        // not use. So warm only once the capture has landed; the capture's completion flushes this.
        // The AX page-text branch is synchronous and has already set .ready, so browsers warm right away.
        if useScreenOCR, contextAssembler.captureState == .pending {
            Diag.log("warm: deferred (OCR capture pending)")
            contextAssembler.pendingWarm = (prefix, postCaret)
            return
        }
        warmAssembledPrompt(prefix: prefix, postCaret: postCaret)
    }

    // Warm the SAME prompt startGeneration() will use (FR-CE-5): assemble the leading-context blocks
    // (instructions/style/clipboard/OCR/post-caret) on main — exactly as startGeneration does at its dispatch
    // point — so the first real keystroke after a focus switch reuses this warm cache instead of paying
    // a cold prefill. Warming bare `prefix` would leave the cache mismatched whenever any context
    // source is on.
    private func warmAssembledPrompt(prefix: String, postCaret: String?) {
        let myGen = bumpGeneration()
        let warmPrompt = assembledPrompt(prefix: prefix, postCaret: postCaret)
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            _ = myGen
            // One token is enough to force the full prefill into the KV cache; we stop immediately and
            // never display warm-up output (side effect = warm ctx).
            try? self.engine.generate(prompt: warmPrompt, maxTokens: 1) { _ in false }
        }
    }

    // Run the focus warm that was deferred behind this focus's first capture (#11). No-op unless one is
    // pending; cancel() drops it, so a keystroke or focus change that arrived first wins.
    private func flushPendingWarm() {
        guard let pending = contextAssembler.pendingWarm else { return }
        contextAssembler.pendingWarm = nil
        Diag.log("warm: capture landed -> warming deferred prefill")
        warmAssembledPrompt(prefix: pending.prefix, postCaret: pending.postCaret)
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

    // Terminate-time unload. Same serialization as unloadModel() — the engine has no internal locking,
    // so freeing its llama context anywhere but `inferenceQueue` can free it out from under an in-flight
    // `llama_decode` — but BLOCKING, because at applicationWillTerminate the process is about to exit and
    // an async unload would simply lose the race. AppDelegate used to call `engine.unload()` straight on
    // main here: quitting mid-suggestion was a use-after-free crash-on-quit. cancel() first so the running
    // decode bails between tokens and this wait stays short.
    func unloadModelAndWait() {
        cancel()
        inferenceQueue.sync { engine.unload() }
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
        if let fix = ghostPresentation.correctionSuggestion { return acceptCorrection(fix) }
        if let emoji = ghostPresentation.emojiSuggestion { return acceptEmoji(emoji) }
        guard suggestionVisible, !ghostPresentation.suggestionText.isEmpty else { return 0 }
        guard let target = acceptanceTarget() else { return 0 }
        let word = SuggestionAcceptor.nextWord(from: ghostPresentation.suggestionText)
        guard !word.isEmpty else { return 0 }
        let injected = inject(word, into: target)
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
        let remainder = String(ghostPresentation.suggestionText.dropFirst(word.count))
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
        if let fix = ghostPresentation.correctionSuggestion { return acceptCorrection(fix) }
        if let emoji = ghostPresentation.emojiSuggestion { return acceptEmoji(emoji) }
        guard suggestionVisible, !ghostPresentation.suggestionText.isEmpty else { return 0 }
        guard let target = acceptanceTarget() else { return 0 }
        let line = SuggestionAcceptor.firstLine(from: ghostPresentation.suggestionText)
        guard !line.isEmpty else { return 0 }
        guard inject(line, into: target) else { return 0 }
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
        guard !ghostPresentation.currentSuggestionAccepted else { return }
        ghostPresentation.currentSuggestionAccepted = true
        wordMeter?.recordSuggestionAccepted()
        // Count distinct accepted suggestions toward retiring the Tab hint (stop writing once retired).
        if tabHintAcceptCount < tabHintThreshold { tabHintAcceptCount += 1 }
    }

    // FR-CTX-3: fold a genuine accepted phrasing into the on-device style profile when enabled.
    // Skips empty/whitespace accepts (consistent with the 0-word
    // emoji/correction paths, which never reach here). StyleProfile itself ignores >12-word pastes.
    private func recordStyle(_ text: String) {
        guard styleProfileEnabled, let styleProfile else { return }
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
    private func inject(_ text: String, into target: AXUIElement) -> Bool {
        SuggestionAcceptor(injector: injector, context: context).inject(text, into: target)
    }

    // Strictly re-resolve the live injection target before comparing focus sequences. The strict read
    // itself advances EditContextTracker's sequence if Tab observes a same-app A→B move before the AX
    // focus notification, closing the stale-visible-ghost race without a cached-element fallback.
    private func acceptanceTarget() -> AXUIElement? {
        SuggestionAcceptor(injector: injector, context: context).acceptanceTarget(
            suggestionFocusSeq: ghostPresentation.suggestionFocusSeq
        ) {
            Diag.log("accept: stale or unresolved focus -> reject")
            bumpGeneration()
            engine.requestCancel()
            clearSuggestion()
        }
    }

    static func focusLatchMatches(_ suggestionFocusSeq: UInt64?, current: UInt64) -> Bool {
        suggestionFocusSeq == current
    }

    static func shouldPreserveHeldSuggestion(isRefire: Bool, visible: Bool, text: String) -> Bool {
        isRefire && visible && !text.isEmpty
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
        guard let base = ghostPresentation.lastRendered?.caretRect, !base.isNull else {
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
        let x = base.minX + (generationSession.rtl ? -advance : advance)
        Diag.log("remainderAnchor: synthetic=\(synthetic) base=\(Int(base.minX)) adv=\(Int(advance)) -> x=\(Int(x))")
        return CGRect(x: x, y: base.minY, width: 0, height: base.height)
    }

    // A reject verdict for the CURRENT snapshot. Before this generation committed a ghost, hide (there is
    // nothing on screen to protect, so the old behaviour is exactly right). After, keep what the user is
    // already reading and merely stop repainting: the filters are non-monotonic, so a later snapshot may
    // well pass again, and retract-then-restore is the worst-looking of the three outcomes. A held
    // context re-fire counts as committed too — the visible ghost there belongs to a deliberately held
    // earlier generation the re-fire is contractually forbidden to replace.
    private func rejectRender(_ reason: String) {
        if (generationSession.committed || generationSession.inContextRefire), suggestionVisible, !ghostPresentation.suggestionText.isEmpty {
            Diag.log("render: \(reason) -> stop (kept visible ghost)")
            return
        }
        Diag.log("render: \(reason) -> hide")
        clearSuggestion()
    }

    private func renderSuggestion(_ rawText: String, checkPrefixDup: Bool = true, caretOverride: CGRect? = nil) {
        guard let focusSeq = generationSession.focusSeq,
              Self.focusLatchMatches(focusSeq, current: context.focusChangeSequence) else {
            Diag.log("render: stale focus -> discard")
            return
        }
        // Rising edge: a fresh completion (not the streamed re-render of a growing ghost, nor the
        // remainder re-render after a word accept — both keep the ghost already-visible). Drives the
        // local acceptance-rate counter and resets the "already accepted" flag for the new suggestion.
        let wasVisible = suggestionVisible
        // Strip cosmetic markup the base (pretrained) model leaks from its web/Markdown training
        // (`<strong>`, `<code>`, `**`, backticks). Done ONCE here so the displayed ghost and the
        // text that Tab/⌥Tab inject (both read `ghostPresentation.suggestionText`) stay identical. Idempotent, so the
        // re-render of the remainder after an accept is a no-op.
        var text: String
        if generationSession.shellMode {
            // Shell-command mode: bypass EVERY prose transform — markup strip (backticks = command
            // substitution), list-marker strip (leading `-` = flag), glue/leading-space reconcile, and the
            // language guards all corrupt shell syntax. Keep exactly one line, then apply the destructive-
            // command guard on the JOINED command (the typed command with the prompt chrome stripped, plus
            // the suggestion) so a split `rm -rf ` + `/` is still caught.
            text = Self.truncatedAtNewline(rawText)
            let fullCommand = Self.shellTypedCommand(generationSession.activePrefix) + text
            // The ONE reject that keeps the right to retract a committed ghost. Every other filter here
            // is a quality judgement whose worst case is a slightly worse suggestion, so it defers to the
            // no-flicker rule; this one is a safety judgement whose worst case is irreversible (`rm -rf `
            // is harmless until ` /` streams in, and the ghost is one Tab from being typed). A one-frame
            // flash on the rare hit is the cheaper side of that trade — and the guard is deliberately
            // narrow, so it is genuinely rare.
            if ShellCommandGuard.isDangerous(fullCommand: fullCommand) {
                Diag.log("render: dangerous command -> hide")
                clearSuggestion(); return
            }
            guard text.contains(where: { !$0.isWhitespace }) else {
                rejectRender("shell empty"); return
            }
        } else {
        text = Self.truncatedAtParagraphBreak(
            Self.strippingLeadingListMarker(Self.sanitizedSuggestion(rawText)))
        // The prefix-relative transforms assume `text` is a FRESH continuation of `generationSession.activePrefix`. They
        // must NOT run on a Tier-2a healed generation (the engine already regenerated the typed word from
        // a clean boundary and stripped the reproduced stem, so `text` is the final word-completion tail —
        // reconciling a leading space would turn "at" into " at") nor on the post-accept remainder
        // re-render (checkPrefixDup:false; already spaced, stale prefix).
        let prefixTransforms = checkPrefixDup && !generationSession.isHealed
        // Reconcile the model's leading separator space with the live prefix so Tab-accept inserts a
        // proper word break. Drop a spurious mid-word glue fragment ("...pot" + "er fer..." -> "poter"):
        // a no-leading-space first token that extends an already-complete word into a non-word — now the
        // common case healing handles directly, so this is the fallback for non-healed continuations.
        if prefixTransforms { text = applyGlueGuard(text, prefix: generationSession.activePrefix) }
        if prefixTransforms { text = Self.reconcileLeadingSpace(suggestion: text, prefix: generationSession.activePrefix) }
        guard !text.isEmpty, !Self.isLowValueSuggestion(text) else {
            rejectRender("low-value"); return
        }
        // Suppress a completion that just loops back over text already typed ("thanks for " +
        // "for reading" -> stutter on inject). Skipped on the accept-remainder re-render, whose
        // `generationSession.activePrefix` is stale (the accepted word isn't folded into it).
        if prefixTransforms, Self.isPrefixDuplicate(suggestion: text, prefix: generationSession.activePrefix) {
            rejectRender("prefix-duplicate"); return
        }
        // Language safety is skipped only on the stale accept-remainder re-render. Unlike the text
        // transforms above, it stays active for healed generations: healing changes token alignment,
        // not whether a confidently wrong-language completion is safe to show.
        if let reason = Self.languageRejectionReason(
            checkPrefixDup: checkPrefixDup, generationIsHealed: generationSession.isHealed,
            prefixLanguage: generationSession.prefixLanguage, suggestion: text, contextLang: generationSession.contextLanguage,
            languageConstraints: generationSession.languageConstraints
        ) {
            rejectRender(reason); return
        }
        }
        // Drop leading newlines (the model often "ends" the line then starts a template) and require
        // at least one printable char — otherwise the ghost would render as invisible whitespace.
        let display = Self.normalizedPresentationPayload(text)
        guard display.contains(where: { !$0.isWhitespace }) else {
            rejectRender("blank/whitespace-only"); return
        }
        let opacity: CGFloat = 1
        ghostPresentation.suggestionText = display
        ghostPresentation.suggestionFocusSeq = focusSeq
        // FR-OV-3/6: anchor at the live caret; OverlayRenderer falls back to a chip if nil. A word-accept
        // remainder re-render passes a predicted anchor (see remainderAnchor) because the live caret is
        // stale until an async synthetic-injection host applies the keystrokes.
        // #9: `generationSession.caretRect` is the caret resolved once for this generation. The user is paused
        // and `generationSession.activePrefix` is fixed, so it cannot move between the ~30 render ticks of one stream —
        // re-reading it per tick was an AX round trip a frame. nil (emoji/correction/shell-history
        // ghosts) still reads live.
        let caret = caretOverride ?? generationSession.caretRect ?? (context.caretRectOnScreen() ?? .null)
        let caretDesc = caret.isNull ? "null" : "\(Int(caret.minX)),\(Int(caret.minY))"
        Diag.log("render: show len=\(display.count) caret=\(caretDesc)")
        Diag.logContent("render: show \"\(display.prefix(40))\"")
        // #2: hold the existing panel geometry across reconcile ticks (every streamed token, the
        // post-accept remainder re-render) unless something the user can see actually changed — focus
        // session, displayed text, caret rect, fade opacity, RTL side, or host font. This kills the
        // post-accept "shift then snap back" jitter from a drifted AX caretRect while still re-anchoring
        // on a real change. #11: anchor the ghost left of the caret in a right-to-left field.
        // Same hoist for the host font (#9): a second AX round trip per tick for a value that is fixed
        // while the field, the caret and the generation are.
        let font = generationSession.font ?? hostFont(caretHeight: caret.height)
        let candidate = OverlayStabilityGate.Rendered(
            text: display, caretRect: caret, focusSeq: focusSeq,
            opacity: opacity, rtl: generationSession.rtl, fontKey: OverlayStabilityGate.fontKey(font))
        if ghostPresentation.shouldPresent(candidate) {
            // FR-OV-4: match the host text size so the ghost reads as part of the field.
            if emit(text: display, at: caret, font: font, opacity: opacity, rtl: generationSession.rtl) {
                // emit() returns true for an actual draw or an exactly presentation-equivalent one.
                ghostPresentation.lastRendered = candidate
            }
        } else {
            Diag.log("render: hold overlay geometry (stable)")
        }
        if !wasVisible {
            ghostPresentation.currentSuggestionAccepted = false
            wordMeter?.recordSuggestionShown()
        }
        suggestionVisible = true
        generationSession.committed = true
    }

    // One stored payload feeds both the overlay and every acceptance path. Leading line breaks that are
    // not drawn and characters beyond the renderer's cap therefore cannot be injected invisibly.
    static func normalizedPresentationPayload(_ text: String) -> String {
        GhostPresentationController.normalizedPayload(text)
    }

    // Smart Compose detection runs once after a generation's final stable payload, never once per
    // streamed frame. This keeps one suggestion from satisfying a multi-suggestion threshold and avoids
    // repeated synchronous AX value reads during rendering.
    private func maybeNoteSmartComposeOverlap(forGeneration generation: Int) {
        guard Self.shouldProbeSmartCompose(
            lastProbedGeneration: generationSession.lastSmartComposeProbeGeneration,
            generation: generation) else { return }
        guard isCurrent(generation), suggestionVisible, ghostPresentation.overlayPresented else { return }
        generationSession.lastSmartComposeProbeGeneration = generation
        guard smartComposeNudgeEnabled else { return }
        guard SmartComposeNudgeStore.shared.mayStillPrompt() else { return }
        // Host comes from the fire()-time snapshot when it is still current (#9) — this runs on every
        // successful render, and the live read walks the AX tree for kAXDocument each time.
        guard let host = currentFocusSnapshot.map(\.domainHost) ?? context.frontmostDomainHost(),
              SmartComposeNudge.isApplicableHost(host) else { return }
        let fieldValue = context.focusedElementText()
        if SmartComposeNudge.detectsOverlap(fieldValue: fieldValue,
                                            prefix: generationSession.activePrefix,
                                            suggestion: ghostPresentation.suggestionText) {
            if SmartComposeNudgeStore.shared.noteOverlap() {
                Diag.log("smartCompose: nudge fired (consecutive overlap threshold reached)")
                NotificationCenter.default.post(name: .shadowtypeShowSmartComposeNudge, object: nil)
            }
        } else {
            SmartComposeNudgeStore.shared.noteNoOverlap()
        }
    }

    static func shouldProbeSmartCompose(lastProbedGeneration: Int?, generation: Int) -> Bool {
        lastProbedGeneration != generation
    }

    // The host text font for the ghost (FR-OV-4): the exact AX font at the caret when the app exposes
    // it, else a system font sized from the caret line height (≈1.17× point size for typical fonts) so
    // web/Electron fields still get a size-matched ghost. nil => OverlayRenderer keeps its default.
    private func hostFont(caretHeight: CGFloat) -> NSFont? {
        // Reuse the fire()-time focus resolution when it is still the live one (#9) so the AX font read
        // doesn't re-walk the tree; fall back to a live read only when there is no current snapshot.
        let axFont = currentFocusSnapshot.map { context.caretFont(in: $0) } ?? context.caretFont()
        if let f = axFont {
            Diag.log("font: host \(f.fontName) \(String(format: "%.1f", f.pointSize))pt (caretH=\(Int(caretHeight)))")
            return f
        }
        // #1: floor the caret height to the smallest seen this focus session before deriving the size,
        // so a single AX poll that returns the coarse full-field-height fallback can't size a giant ghost.
        let stableHeight = ghostPresentation.fontStabilizer.stabilizedCaretHeight(caretHeight,
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
        GhostPresentationController.correctionGhostMinX(
            caretMinX: caretMinX,
            run: run,
            font: font
        )
    }

    private func clearSuggestion() {
        ghostPresentation.clear(preserveEmitState: generationSession.inContextRefire)
        // The hold flag is single-shot: any explicit clear during/after a re-fire (deadline-drop,
        // confidence reject, fire() early-out from a guard) must end the hold so the next genuine
        // emission isn't suppressed by stale state. The gen-done handler also clears it on success.
        generationSession.inContextRefire = false
        // Any coalesced token render queued for the now-gone ghost is moot — drop it.
        generationSession.clearPendingStream()
        suggestionVisible = false   // didSet notifies the Tab swallow only on transition
        generationSession.committed = false // nothing on screen → the next reject may hide freely
        // The hoisted per-generation geometry/language belong to the ghost that just went away (#9);
        // the next show must resolve its own rather than paint at a dead caret.
        generationSession.caretRect = nil
        generationSession.font = nil
        generationSession.prefixLanguage = nil
        generationSession.languageConstraints = []
        generationSession.focusSeq = nil
    }

    // MARK: - Host font watch (FR-OV-4)

    private func startFontWatch() {
        ghostPresentation.startFontWatch { [weak self] in
            self?.revalidateHostFont()
        }
    }

    private func stopFontWatch() {
        ghostPresentation.stopFontWatch()
    }

    // Re-read the host font for the visible completion ghost; re-render in place only if it changed.
    // No regeneration — same text, same focus session — so it cannot churn or shift the suggestion.
    // Scope: only the gate-tracked completion ghost (ghostPresentation.lastRendered != nil). Emoji/correction
    // ghosts untrack themselves, so they're skipped here.
    private func revalidateHostFont() {
        guard suggestionVisible, let last = ghostPresentation.lastRendered, !last.text.isEmpty else { return }
        guard context.focusChangeSequence == last.focusSeq else { return }
        let caret = context.caretRectOnScreen() ?? last.caretRect
        let font = hostFont(caretHeight: caret.height)
        let newKey = OverlayStabilityGate.fontKey(font)
        guard newKey != last.fontKey else { return }
        Diag.log("font: host font changed while visible -> re-render (\(last.fontKey ?? "default") -> \(newKey ?? "default"))")
        // Keep the per-generation hoist in step, or a later coalesced render tick would repaint with the
        // stale font this call just replaced (#9).
        generationSession.font = font
        // Bypass emit()'s identical-text dedup: the text is unchanged by design, so emit() would drop
        // this deliberate in-place re-font. Drive overlay.show directly and resync the gate snapshot.
        ghostPresentation.showDirect(
            text: last.text,
            at: caret,
            font: font,
            opacity: last.opacity,
            rtl: last.rtl,
            showHint: tabHintActive
        )
        ghostPresentation.lastRendered = OverlayStabilityGate.Rendered(
            text: last.text, caretRect: caret, focusSeq: last.focusSeq,
            opacity: last.opacity, rtl: last.rtl, fontKey: newKey)
    }

    // Single owner of the stability-gate snapshot reset. The emoji/correction ghosts and clearSuggestion
    // all bypass the gate, so they must drop the last-rendered snapshot or the next completion render
    // could wrongly HOLD a stale frame (#12). Centralized so no show-path can forget it.
    private func untrackOverlay() {
        ghostPresentation.untrackOverlay()
    }

    // Single funnel for every overlay.show() in the file. Catches an identical re-emission on the same
    // focus session within a short window — the dominant "shows twice" pattern when an OCR re-fire (or
    // any path that clears and re-renders) regenerates the exact text the user just saw. The
    // OverlayStabilityGate runs upstream for caret/font geometry; this gate runs at the metal boundary
    // and persists across clearSuggestion()/untrackOverlay() so the gate's reset can't defeat it.
    @discardableResult
    private func emit(text: String, at caret: CGRect, font: NSFont?, opacity: CGFloat, rtl: Bool) -> Bool {
        ghostPresentation.emit(
            text: text,
            at: caret,
            font: font,
            opacity: opacity,
            rtl: rtl,
            showHint: tabHintActive,
            focusSeq: context.focusChangeSequence,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    // Text-only emit dedup is insufficient: a stability-approved caret/font/opacity/RTL/hint change is a
    // real presentation update even when the string is unchanged. Keep the independent dedup gate, but
    // key it on the complete presentation reaching OverlayRenderer.
    static func presentationFingerprint(text: String, caret: CGRect, font: NSFont?,
                                        opacity: CGFloat, rtl: Bool, showHint: Bool) -> String {
        GhostPresentationController.presentationFingerprint(
            text: text,
            caret: caret,
            font: font,
            opacity: opacity,
            rtl: rtl,
            showHint: showHint
        )
    }

    // MARK: - Emoji mode (FR-EM-1)

    // Show `emoji` as the ghost; remember the typed `:shortcode` run length so accept can delete it.
    private func showEmoji(_ emoji: String, queryLength: Int) {
        let opacity: CGFloat = 1
        ghostPresentation.emojiSuggestion = emoji
        ghostPresentation.emojiQueryLength = queryLength
        ghostPresentation.suggestionText = emoji
        ghostPresentation.suggestionFocusSeq = context.focusChangeSequence
        let caret = context.caretRectOnScreen() ?? .null
        emit(text: emoji, at: caret, font: hostFont(caretHeight: caret.height), opacity: opacity, rtl: false)
        untrackOverlay()                // emoji ghost isn't tracked by the stability gate
        suggestionVisible = true
    }

    // Replace the typed `:shortcode` run with the emoji via the Injector's atomic before-caret replace.
    // Counts 0 words (FR-EM-1). Shortcodes are ASCII, so utf16 == keystroke count == ghostPresentation.emojiQueryLength.
    private func acceptEmoji(_ emoji: String) -> Int {
        guard let target = acceptanceTarget() else { return 0 }
        guard SuggestionAcceptor(injector: injector, context: context).replaceBeforeCaret(
            utf16Length: ghostPresentation.emojiQueryLength,
            keystrokeCount: ghostPresentation.emojiQueryLength,
            with: emoji,
            in: target
        ) else { return 0 }
        clearSuggestion()
        return 0
    }

    // MARK: - Autocorrect mode (FR-AC-1)

    // Show `fix` as a special correction ghost over the mistyped `run`. Unlike a forward completion the
    // correction REPLACES already-typed text, so the ghost is drawn shifted LEFT by the run's rendered
    // width to sit over the typo (rather than appended after the caret, which would read as "tehthe").
    // Mirrors showEmoji() — never calls the model. `run` is the raw mistyped token (its utf16/keystroke
    // lengths drive the atomic delete on accept).
    private func showCorrection(_ fix: String, run: String) {
        let opacity: CGFloat = 1
        ghostPresentation.correctionSuggestion = fix
        ghostPresentation.correctionRun = run
        ghostPresentation.suggestionText = fix
        ghostPresentation.suggestionFocusSeq = context.focusChangeSequence
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
        guard let run = ghostPresentation.correctionRun,
              let target = acceptanceTarget() else { return 0 }
        guard SuggestionAcceptor(injector: injector, context: context).replaceBeforeCaret(
            utf16Length: run.utf16.count,
            keystrokeCount: run.count,
            with: fix,
            in: target
        ) else { return 0 }
        clearSuggestion()
        return 0
    }

    // MARK: - OCR context (FR-CTX-1, gated)

    // Refresh the style-hint snapshot on focus-in (FR-CTX-3). Computes the (sorted) hint once off the
    // per-keystroke path; assembledPrompt then reads the cached string. nil when disabled/empty.
    private func refreshStyleHintIfEnabled() {
        let budget = Self.styleHintChars(forStrength: personalizationStrength)
        guard styleProfileEnabled, budget > 0, let styleProfile else {
            contextAssembler.setStyleHint(nil)
            return
        }
        let hint = styleProfile.styleHint(maxChars: budget)
        contextAssembler.setStyleHint(hint)
    }

    // Map the Personalization strength (0...3) to a style-hint char budget. 0 disables the hint
    // entirely; higher steps prepend more characteristic phrasing, biasing generation harder toward
    // the user's voice. Pure + testable (no AX/model). 200 (strength 2) is the .medium anchor.
    static func styleHintChars(forStrength strength: Int) -> Int {
        CompletionContextAssembler.styleHintChars(forStrength: strength)
    }

    // `prefix` is the user's live text-before-caret; it is what the capture is de-duplicated AGAINST
    // before being cached (see dedupedCapture). `snapshot` is fire()'s single focus resolution, reused
    // for the AX page read instead of re-walking the tree (#9).
    private func refreshOCRContextIfEnabled(prefix: String,
                                            snapshot: EditContextTracker.FocusSnapshot? = nil) {
        guard useScreenOCR else { return }
        let maxChars = ocrContextChars
        let capturedBundleId = context.frontmostBundleId
        let capturedFocusSeq = snapshot?.focusSeq ?? context.focusChangeSequence
        let capturedGeneration = currentGeneration()

        // Arm the first-capture gate only when we have NO context yet for this focus; a re-capture while
        // context already exists must not flip back to .pending (that would hide the warm, stale ghost).
        contextAssembler.markCapturePendingIfEmpty()

        // AX-FIRST for an actual web-area snapshot, but never walk it synchronously on main. Filtering,
        // cache assembly, and OCR fallback all happen from the cancellable completion.
        if let snapshot, snapshot.webArea != nil {
            context.requestPageContextText(in: snapshot) { [weak self] ax in
                guard let self, self.captureIsCurrent(
                    generation: capturedGeneration,
                    focusSeq: capturedFocusSeq,
                    bundleId: capturedBundleId) else { return }
                if let ax, !ax.isEmpty {
                    let text = self.dedupedCapture(
                        ScreenContextProvider.clamp(
                            ScreenContextProvider.denoise(ax, dropShortLines: false),
                            to: self.pageContextChars),
                        prefix: prefix)
                    let changed = self.storeOCRCache(text)
                    self.contextAssembler.captureState = .ready
                    Diag.log("pagectx: ax raw=\(ax.count) kept=\(text?.count ?? -1) changed=\(changed)")
                    Diag.logContent("pagectx: ax head=\"\(ax.prefix(200))\"")
                    self.flushPendingWarm()
                    if changed { self.maybeRefireForContext() }
                } else {
                    self.requestScreenCapture(
                        prefix: prefix,
                        maxChars: maxChars,
                        bundleId: capturedBundleId,
                        focusSeq: capturedFocusSeq,
                        generation: capturedGeneration)
                }
            }
            return
        }

        // No focus snapshot/web area: fall directly to OCR instead of a second synchronous AX walk.
        requestScreenCapture(prefix: prefix, maxChars: maxChars, bundleId: capturedBundleId,
                             focusSeq: capturedFocusSeq, generation: capturedGeneration)
    }

    private func requestScreenCapture(prefix: String, maxChars: Int, bundleId: String?,
                                      focusSeq: UInt64, generation: Int) {
        guard let screenContext else {
            contextAssembler.captureState = .ready
            flushPendingWarm()
            return
        }
        Task { [weak self] in
            let text = await screenContext.recentText(maxChars: maxChars)
            guard let self else { return }
            await MainActor.run {
                guard self.captureIsCurrent(
                    generation: generation, focusSeq: focusSeq, bundleId: bundleId) else { return }
                let changed = self.storeOCRCache(self.dedupedCapture(text, prefix: prefix))
                self.contextAssembler.captureState = .ready
                Diag.log("ocr: refresh got \(text?.count ?? -1) chars changed=\(changed)")
                // The capture this focus's KV warm was waiting on has landed (#11).
                self.flushPendingWarm()
                // Fresh context for the current viewport → re-fire so the ghost reflects it (closes the
                // focus-in race + scroll staleness). Bounded to ONE upgrade per prefix so a dynamic
                // screen can't keep regenerating and cycling the ghost during a pause.
                if changed { self.maybeRefireForContext() }
            }
        }
    }

    private func captureIsCurrent(generation: Int, focusSeq: UInt64, bundleId: String?) -> Bool {
        Self.captureLatchMatches(
            capturedGeneration: generation,
            currentGeneration: currentGeneration(),
            capturedFocusSeq: focusSeq,
            currentFocusSeq: context.focusChangeSequence,
            capturedBundleId: bundleId,
            currentBundleId: context.frontmostBundleId)
    }

    static func captureLatchMatches(capturedGeneration: Int, currentGeneration: Int,
                                    capturedFocusSeq: UInt64, currentFocusSeq: UInt64,
                                    capturedBundleId: String?, currentBundleId: String?) -> Bool {
        CompletionContextAssembler.captureLatchMatches(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration,
            capturedFocusSeq: capturedFocusSeq,
            currentFocusSeq: currentFocusSeq,
            capturedBundleId: capturedBundleId,
            currentBundleId: currentBundleId
        )
    }

    // Strip the user's own document + draft from a raw capture BEFORE it is cached (#10).
    //
    // This used to happen ONLY on the prompt path (assembledPrompt), so what was cached was the raw
    // capture — draft and all. `storeOCRCache`'s whole job is to answer "did the visible text
    // MEANINGFULLY change?", and with the growing draft baked in the answer was "yes" on essentially
    // every fire: the change-guard was defeated, the context re-fire path ran constantly, and the cached
    // block (which sits in FRONT of the prefix) moved under the KV cache every time. De-duplicating
    // first makes the cached block hold still for as long as the screen actually holds still.
    // The prompt path still runs the same two filters — by then the prefix has grown past this capture,
    // and both filters are stable/idempotent, so the second pass is a cheap no-op in the steady state.
    private func dedupedCapture(_ text: String?, prefix: String) -> String? {
        CompletionContextAssembler.dedupedCapture(text, prefix: prefix)
    }

    // Update the OCR context cache, returning whether it MEANINGFULLY changed. OCR jitter (reflowed line
    // breaks, trailing spaces) must not count as a change, or every re-capture would shift the prompt's
    // leading `Context:` tokens and force a cold prefill on the next keystroke (FR-CE-5). When unchanged
    // we keep the existing value so KV stays warm and the caller skips the re-fire.
    // Main-thread only (every caller is), which is what lets it also latch `contextAssembler.ocrLanguage`.
    @discardableResult
    private func storeOCRCache(_ text: String?) -> Bool {
        let changed = contextAssembler.storeOCR(text) { capturedText in
            let declared = UserDefaults.standard.string(forKey: Self.personalizeLanguagesKey) ?? ""
            let languageConstraints = Self.parsePersonalizedLanguages(declared)
            return Self.dominantLanguage(
                Self.caretLocalContextTail(capturedText),
                minConfidence: 0.70,
                languageConstraints: languageConstraints
            )
        }
        Diag.log("context: capture steerLang=\(contextAssembler.ocrLanguage?.rawValue ?? "nil")")
        return changed
    }

    // Two OCR blocks are equivalent when they match after collapsing all whitespace/newline runs to a
    // single space and trimming — so cosmetic OCR reflow doesn't read as a content change. Pure + testable.
    static func ocrTextEquivalent(_ a: String?, _ b: String?) -> Bool {
        CompletionContextAssembler.ocrTextEquivalent(a, b)
    }
    static func normalizeOCRForCompare(_ s: String?) -> String {
        CompletionContextAssembler.normalizeOCRForCompare(s)
    }

    // Re-fire generation for a freshly-changed on-screen context — but at most ONCE per prefix, so a
    // dynamic screen can't keep regenerating and cycling the ghost while the user is paused. The cache
    // is already updated (storeOCRCache), so the next keystroke still uses the latest context.
    private func maybeRefireForContext() {
        guard Self.shouldRefireForContext(count: contextAssembler.refireCount, max: Self.maxContextRefires) else {
            Diag.log("ocr: skip re-fire (cap reached)")
            return
        }
        contextAssembler.refireCount += 1
        // Flip the silent-hold flag so the upcoming generation can hold the visible ghost while its
        // tokens reproduce the prior suggestion (the dominant "regenerates the same text" case after
        // an OCR-context refresh). Cleared on stream divergence or in the gen-done handler.
        generationSession.inContextRefire = suggestionVisible && !ghostPresentation.suggestionText.isEmpty
        fire()
    }

    // Pure cap decision (testable): allow the context-upgrade re-fire only until the per-focus-session
    // cap is reached. cancel() resets the count on each keystroke/focus change/force-activate, so a new
    // typing action gets exactly one upgrade and a sustained pause gets none after the first — immune to
    // the prefix-read drift that defeated the earlier per-prefix latch.
    static func shouldRefireForContext(count: Int, max: Int) -> Bool {
        CompletionContextAssembler.shouldRefire(count: count, maximum: max)
    }

    // Pure (testable): on a web-mail host, strip the trailing quoted-reply tail of `prefix`. Outside
    // web mail or with a nil prefix, returns the input unchanged — so the email-specific rule never
    // touches normal prose contexts. Used as the prompt prefix when the caret sits inside or below the
    // quoted-history block (Gmail "Show trimmed content"), preventing a ghost that just keeps quoting.
    static func prefixAfterEmailQuoteStrip(_ prefix: String?, host: String?) -> String? {
        CompletionContextAssembler.prefixAfterEmailQuoteStrip(prefix, host: host)
    }

    // Generalized leading-context assembly (FR-CTX-1/2/3, FR-PA-3). Prepends enabled sources in order:
    //   1. effectiveInstruction (FR-PA-3) — the global/per-app instruction, FIRST (highest steer).
    //   2. styleHint            (FR-CTX-3) — the user's writing-style bias.
    //   3. clipboard            (FR-CTX-2) — current pasteboard text.
    //   4. OCR                  (FR-CTX-1, Free) — recent on-screen text (its own `useScreenOCR` toggle,
    //                                              NOT licence-gated; it is a Free feature).
    //   5. postCaret            — the text FOLLOWING the caret (see postCaretBlock), last so it sits
    //                             immediately before the `Text:` marker. nil off the native AX read
    //                             paths and in shell mode.
    // wrapped as `Context:\n<blocks>\n\nText:\n<prefix>` so the base model conditions on the context
    // (see assemblePrompt). The prefix STAYS the forward-from-caret tail (FR-CE-9). Free default
    // (no licence, OCR off, nothing after the caret) yields exactly `prefix` up to the budget, and an
    // ANCHORED tail window of it beyond — either way the prompt head holds still across a burst, so KV
    // reuse is preserved.
    private func tokenizerBudgetedPrompt(
        prefix: String,
        postCaret: String?
    ) -> CompletionContextAssembler.PreparedPrompt {
        let defaultBudget = promptCharBudget
        let effectiveCap = max(8, min(engine.maxContextTokens, engine.contextWindowTokens - 256))
        return contextAssembler.tokenizerBudgetedPrompt(
            defaultBudget: defaultBudget,
            effectiveTokenCap: effectiveCap
        ) { budget in
            assembledPrompt(prefix: prefix, postCaret: postCaret, totalChars: budget)
        }
    }

    private func storeTokenizerValidatedBudget(_ budget: Int, for key: PromptSectionBudget.CacheKey) {
        contextAssembler.storeTokenizerValidatedBudget(budget, for: key)
    }

    private func assembledPrompt(prefix: String, postCaret: String?, totalChars: Int? = nil) -> String {
        // Resolve each (already-gated-ready) source, then hand the gating + ordering + join to the pure
        // static below so it is unit-testable without AX/model/overlay (the leak-when-unlicensed property
        // is the security-critical invariant). Style hint is the focus-in snapshot (stable across the
        // burst); OCR is read from its warm cache.
        let instruction = instructionStore?.effectiveInstruction(bundleId: context.frontmostBundleId)
        let styleHint = contextAssembler.cachedStyleHint
        let clip = clipboardContextEnabled
            ? clipboard?.recentText(maxChars: clipboardContextChars) : nil
        let ocrRaw = contextAssembler.cachedOCR
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
        // stripped). Stash it for renderSuggestion's drift suppression (only if that context survives the
        // budget — see below), and pass its English name to the assembler so the `Text (in <Language>):`
        // marker steers the base model toward it. nil when
        // there's no confident single-language context → behaviour unchanged.
        // Detect the steer language from the context NEAREST the caret, not the whole capture. Slack and
        // most chat apps expose no AX web-area, so the context is a full-screen OCR dominated by English
        // UI chrome (sidebar, channels, menus); detecting on the whole blob returns English and the
        // Catalan/other-language steer never fires (proven: whole Slack OCR -> en:1.00, the conversation
        // tail -> ca:1.00; the base model then drifts "has trob" -> Spanish "trobado"). The recent
        // messages at the tail carry the reply language. (Never detect from the short prefix — 8 chars of
        // "has trob" misreads as English at 0.95.)
        // Read from the per-CAPTURE latch rather than re-detecting here (#10): this runs on every fire,
        // and a borderline read that flips between fires rewrites the `Text (in X):` marker sitting
        // immediately before the prefix — the prompt head — which costs a full cold re-prefill. Still
        // gated on the OCR block actually existing, so a run with no screen context keeps the bare
        // `Text:` marker exactly as before.
        let ctxLang = (useScreenOCR && ocr != nil) ? contextAssembler.ocrLanguage : nil

        let assembled = Self.assemblePrompt(
            prefix: prefix,
            instruction: instruction,
            styleHint: styleHint, styleEnabled: styleProfileEnabled,
            clipboard: clip, clipboardEnabled: clipboardContextEnabled,
            ocr: ocr, ocrEnabled: useScreenOCR,
            postCaret: postCaret,
            steerLanguageName: ctxLang.flatMap(Self.englishLanguageName),
            totalChars: totalChars ?? promptCharBudget)
        // Arm renderSuggestion's context-drift suppression ONLY when the OCR block actually SURVIVED the
        // budget. A long draft eats most of the budget and the lowest-priority OCR block is dropped — the
        // model then never sees that context at all, so hiding its completion for "drifting" from it hides
        // a perfectly good ghost on evidence the model was never given. Committed after assembly for that
        // reason (it used to be set from the pre-assembly detection, which couldn't know). Deliberately
        // asymmetric with the steer marker above, which still carries the detected name: steering toward
        // the language the user is actually writing in is harmless when the block is gone; HIDING is not.
        generationSession.contextLanguage = assembled.ocrKept ? ctxLang : nil
        return assembled.prompt
    }

    // English display name for a detected language ("ca" -> "Catalan"), used to steer the base model in
    // the prompt's `Text (in <Language>):` marker. Forced to the en_US locale so the name is the model's
    // expected English form regardless of the user's UI locale. nil if the code has no known name.
    static func englishLanguageName(_ language: NLLanguage) -> String? {
        Locale(identifier: "en_US").localizedString(forLanguageCode: language.rawValue)
    }

    private static let personalizeLanguagesKey = "shadowtype.personalize.languages"
    private static let personalizedLanguageCandidates =
        Locale.LanguageCode.isoLanguageCodes.map { NLLanguage($0.identifier) }
    private static let personalizedLanguageLookup: (
        byCode: [String: NLLanguage],
        byName: [String: NLLanguage]
    ) = {
        let locale = Locale(identifier: "en_US")
        var byCode: [String: NLLanguage] = [:]
        var byName: [String: NLLanguage] = [:]
        for language in personalizedLanguageCandidates {
            byCode[language.rawValue.lowercased(with: locale), default: language] = language
            if let name = englishLanguageName(language)?.lowercased(with: locale) {
                byName[name, default: language] = language
            }
        }
        return (byCode, byName)
    }()

    // Parse onboarding's free-text language list without consulting defaults. English display names and
    // raw ISO codes are both accepted case-insensitively; unknown entries are ignored and duplicates
    // collapse while preserving the user's order.
    static func parsePersonalizedLanguages(_ value: String) -> [NLLanguage] {
        guard value.contains(where: { !$0.isWhitespace }) else { return [] }
        let locale = Locale(identifier: "en_US")
        let lookup = personalizedLanguageLookup
        var seen = Set<NLLanguage>()
        return value.split(separator: ",").compactMap { rawToken in
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(with: locale)
            guard let language = lookup.byCode[token] ?? lookup.byName[token],
                  seen.insert(language).inserted else {
                return nil
            }
            return language
        }
    }

    // #8: global BYTE ceiling for the assembled prompt (context blocks + prefix). MIRRORED FROM the
    // engine's live token cap by AppDelegate.syncToggles, right next to where it sets
    // `engine.maxContextTokens` — THE TWO MUST STAY IN SYNC. They used to drift: this was hardcoded to
    // 6000 ("well inside the engine's 4096-token window"), but the window is the USER's
    // `shadowtype.contextWindowTokens` setting, 1024 by default. InferenceEngine.generate() front-trims
    // the tokenized prompt to that cap, and the FRONT is exactly where `Context:\n` + instruction +
    // style + clipboard + OCR live — so every context block we paid to build was decapitated and the
    // model got a headless fragment glued to `\n\nText:\n`, the flat-document shape the framing below
    // exists to avoid. This default mirrors the 1024-token default of that key.
    var promptCharBudget = CompletionCoordinator.promptBudgetBytes(forContextTokens: 1024)

    // Pure (testable): prompt bytes that safely fit `tokens` tokens. 3.5 bytes/token is deliberately
    // BELOW the ~4 bytes/token of mixed English prose: under-filling only wastes a little of the window,
    // while over-filling reintroduces the front-trim that eats the context blocks. The reserve covers the
    // framing the section budget is not charged for — `Context:\n`, the `\n\n` block separators and the
    // longest `\n\nText (in <Language>):\n` marker.
    static func promptBudgetBytes(forContextTokens tokens: Int) -> Int {
        CompletionContextAssembler.promptBudgetBytes(forContextTokens: tokens)
    }

    // MARK: - Post-caret conditioning (suffix awareness)

    // How much post-caret text ever reaches the prompt. Deliberately far below
    // EditContextTracker.maxSuffixChars (400 UTF-16 units): the job is to let the model SEE that a
    // paragraph follows so it doesn't duplicate or contradict it, and the first couple of sentences
    // carry that; anything more is budget taken from the caret text and from screen context. Bytes, to
    // match the allocator's unit.
    static let postCaretContextBytes = CompletionContextAssembler.postCaretContextBytes

    // Pure (testable): the `After the cursor:` context block for the text following the caret, or nil
    // when there is nothing worth telling the model.
    //
    // WHY this block exists: caretAtLineEnd() means "the next character is a newline", NOT
    // end-of-document, so when the user edits paragraph 2 of a 5-paragraph mail the model has been told
    // nothing at all about the three paragraphs below and happily writes a sentence that duplicates or
    // contradicts them. This is the base-model route to fixing that: no FIM tokens (the engine supports
    // params.fim, but no catalog model exposes the tokens, so that path is unreachable today) — just one
    // more `Header:\n…` block inside the existing `Context:` region, the same document-shaped framing
    // that makes a base model treat `Context:` as reference material and `Text:` as the live
    // continuation. The label deliberately avoids the literal `Text:` / `Text (` sequences, which are
    // stop markers on the rewrite path (SamplingParams.rewriteDefaults) and the marker this prompt ends
    // with; "cursor" rather than the codebase's "caret" because this string is read by a model trained
    // on ordinary prose, not by a developer.
    //
    // KV STABILITY (the make-or-break — this block sits in FRONT of the prefix): every step here is a
    // pure function of `suffix` alone, and `suffix` itself is the text the user is NOT editing, so the
    // whole block is byte-identical across a typing burst. The cut keeps the HEAD (nearest the caret)
    // and is taken at a fixed cost, never at "whatever the budget has left" — see the atomic flag in
    // assemblePrompt for the other half of that guarantee.
    static func postCaretBlock(_ suffix: String?,
                               maxBytes: Int = CompletionCoordinator.postCaretContextBytes) -> String? {
        CompletionContextAssembler.postCaretBlock(suffix, maxBytes: maxBytes)
    }

    // Compatibility witness for historical Free/paid prompt-gating tests. The live product never calls
    // this overload; it uses the unlocked overload below, so licensing is absent from the runtime path.
    static func assemblePrompt(prefix: String, isLicensed: Bool,
                               instruction: String?,
                               styleHint: String?, styleEnabled: Bool,
                               clipboard: String?, clipboardEnabled: Bool,
                               ocr: String?, ocrEnabled: Bool,
                               postCaret: String? = nil,
                               steerLanguageName: String? = nil,
                               totalChars: Int = .max) -> (prompt: String, ocrKept: Bool) {
        assemblePrompt(
            prefix: prefix,
            instruction: isLicensed ? instruction : nil,
            styleHint: styleHint, styleEnabled: isLicensed && styleEnabled,
            clipboard: clipboard, clipboardEnabled: isLicensed && clipboardEnabled,
            ocr: ocr, ocrEnabled: ocrEnabled,
            postCaret: postCaret,
            steerLanguageName: steerLanguageName,
            totalChars: totalChars)
    }

    // Pure unlocked leading-context assembly. Kept as a compatibility wrapper for existing callers.
    static func assemblePrompt(prefix: String,
                               instruction: String?,
                               styleHint: String?, styleEnabled: Bool,
                               clipboard: String?, clipboardEnabled: Bool,
                               ocr: String?, ocrEnabled: Bool,
                               postCaret: String? = nil,
                               steerLanguageName: String? = nil,
                               totalChars: Int = .max) -> (prompt: String, ocrKept: Bool) {
        CompletionContextAssembler.assemblePrompt(
            prefix: prefix,
            instruction: instruction,
            styleHint: styleHint,
            styleEnabled: styleEnabled,
            clipboard: clipboard,
            clipboardEnabled: clipboardEnabled,
            ocr: ocr,
            ocrEnabled: ocrEnabled,
            postCaret: postCaret,
            steerLanguageName: steerLanguageName,
            totalChars: totalChars,
            trimmingPrefix: { trimmingTrailingInlineWhitespace($0) }
        )
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
    // its OWN current line, with the prompt chrome stripped (shellTypedCommand), becomes the typed command
    // — earlier prefix lines are ignored in favour of the richer buffer exemplars.
    static func assembleShellPrompt(prefix: String, terminalBuffer: String?, totalChars: Int = 4000) -> String {
        // Redacted like the exemplars are: a secret the user is typing RIGHT NOW is the one most worth not
        // handing to the model, and it used to be the only part of the prompt that went in verbatim.
        let typed = redactingSecrets(trimmingTrailingInlineWhitespace(shellTypedCommand(prefix)))
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

    // The current command line being typed: the tail of `prefix` after the last newline. RAW — in a
    // terminal it still carries the live PS1. Consumers want shellTypedCommand below.
    static func shellCurrentLine(_ prefix: String) -> String {
        if let nl = prefix.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(prefix[prefix.index(after: nl)...])
        }
        return prefix
    }

    // The command the user is TYPING: the current line with the terminal's prompt chrome stripped
    // (`dario@mac ~/proj % git pu` -> `git pu`), using the same sigil rule that made this a shell prompt
    // in the first place (ActivationPolicy.isShellPromptLine / shellCommandAfterSigil).
    //
    // Every consumer of the current line used to get the RAW line, chrome and all, which broke all three:
    // assembleShellPrompt emitted `$ dario@mac ~/proj % git pu` as its continuation line — not
    // command-shaped, and duplicating the stem the exemplars already end with; ShellHistory.prefixMatch
    // compared that chrome-laden stem against chrome-STRIPPED history commands, so the zero-hallucination
    // fast path could never hit; and the destructive-command guard tokenized `dario@mac …` and saw a
    // first token that is not `rm`, so `rm -rf /` sailed straight through it.
    //
    // Falls back to the raw line when it carries no sigil (some terminals expose only the typed text —
    // that is the shape every existing test uses). Trailing whitespace is deliberately PRESERVED:
    // shellCommandAfterSigil trims both ends, but a typed `git ` must complete to `status`, not
    // ` status`, and the guard must see the space in `rm -rf ` + `/`.
    static func shellTypedCommand(_ prefix: String) -> String {
        CompletionActivationEvaluator.shellTypedCommand(prefix)
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
        CompletionActivationEvaluator.redactingSecrets(line)
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
        CompletionActivationEvaluator.endsCompleteStatement(prefix)
    }

    // True when the suggestion is confidently in a DIFFERENT language than the prefix — the cross-language
    // drift a base model sometimes emits. Deliberately conservative: requires a reasonably long prefix and
    // a HIGH-confidence read on BOTH sides before suppressing, because NLLanguageRecognizer is noisy on
    // short text. Returns false on any ambiguity, so good completions are never collateral. Pure-ish
    // (NaturalLanguage only, no I/O) and testable.
    static func languageDrifts(prefix: String, suggestion: String,
                               minPrefixChars: Int = 40, minConfidence: Double = 0.80,
                               languageConstraints: [NLLanguage] = []) -> Bool {
        languageDrifts(prefixLanguage: driftPrefixLanguage(prefix, minPrefixChars: minPrefixChars,
                                                           minConfidence: minConfidence,
                                                           languageConstraints: languageConstraints),
                       suggestion: suggestion, minConfidence: minConfidence,
                       languageConstraints: languageConstraints)
    }

    // The prefix half of the drift read, split out so the caller can compute it ONCE per generation
    // instead of once per streamed render tick (#9) — `generationSession.activePrefix` cannot change while the model is
    // streaming. nil = too short or not confident enough, i.e. the guard must not fire.
    static func driftPrefixLanguage(_ prefix: String,
                                    minPrefixChars: Int = 40, minConfidence: Double = 0.80,
                                    languageConstraints: [NLLanguage] = []) -> NLLanguage? {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= minPrefixChars else { return nil }
        return dominantLanguage(p, minConfidence: minConfidence,
                                languageConstraints: languageConstraints)
    }

    // The per-tick half: only the (growing) suggestion is re-read.
    static func languageDrifts(prefixLanguage: NLLanguage?, suggestion: String,
                               minConfidence: Double = 0.80,
                               languageConstraints: [NLLanguage] = []) -> Bool {
        guard let pl = prefixLanguage else { return false }
        let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4,
              let sl = dominantLanguage(s, minConfidence: minConfidence,
                                        languageConstraints: languageConstraints) else { return false }
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
                                               minConfidence: Double = 0.80,
                                               languageConstraints: [NLLanguage] = []) -> Bool {
        let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= minSuggestionChars,
              let sl = dominantLanguage(s, minConfidence: minConfidence,
                                        languageConstraints: languageConstraints) else { return false }
        return sl != contextLang
    }

    // Pure render policy for the two language backstops. `generationSession.isHealed` is deliberately not a
    // gate: healing only exempts prefix-relative text transforms. `checkPrefixDup == false` identifies
    // the stale accept-remainder re-render, where both language comparisons must stay skipped.
    static func languageRejectionReason(checkPrefixDup: Bool, generationIsHealed _: Bool,
                                        prefixLanguage: NLLanguage?, suggestion: String,
                                        contextLang: NLLanguage?,
                                        languageConstraints: [NLLanguage] = []) -> String? {
        guard checkPrefixDup else { return nil }
        if languageDrifts(prefixLanguage: prefixLanguage, suggestion: suggestion,
                          languageConstraints: languageConstraints) {
            return "lang-drift"
        }
        if let contextLang,
           suggestionConflictsWithContext(suggestion: suggestion, contextLang: contextLang,
                                          languageConstraints: languageConstraints) {
            return "context-lang conflict"
        }
        return nil
    }

    // Best-guess language of `text`, but only when the top hypothesis clears `minConfidence` and leads
    // the runner-up by a safe margin; else nil.
    // The de-chromed context nearest the caret (last few non-empty lines), for LANGUAGE detection only.
    // A full-screen OCR capture is mostly far-away UI chrome whose language (usually English) drowns out
    // the conversation; the recent messages at the tail are the reply language. Pure + testable.
    static func caretLocalContextTail(_ text: String, maxLines: Int = 6, maxChars: Int = 400) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        return tail.count <= maxChars ? tail : String(tail.suffix(maxChars))
    }

    // The declared languages are a TIE-BREAK, never a filter. Reading unconstrained first is what keeps
    // a language the user never declared detectable: measured, an undeclared German sentence scores
    // de:1.00 open but en:0.71 when constrained to {en,es,ca} — confident enough to clear both gates
    // below and steer a German thread into English. So the open read always wins when it is confident.
    static func dominantLanguage(_ text: String, minConfidence: Double,
                                 languageConstraints: [NLLanguage] = []) -> NLLanguage? {
        if let open = confidentLanguage(text, minConfidence: minConfidence, constraints: []) {
            return open
        }
        // Only where the open read was NOT confident do the declared languages get to disambiguate.
        // Apple scores close Romance pairs flat on short text ("la solucio jo la tiraria mes per alla"
        // reads ca:0.76/it:0.19 open, ca:0.94/es:0.06 constrained), which is the case this exists for.
        // This can never invent a language: it only picks among the ones the user says they write in,
        // and only where the unconstrained read would have returned nil.
        guard !languageConstraints.isEmpty else { return nil }
        return confidentLanguage(text, minConfidence: minConfidence, constraints: languageConstraints)
    }

    private static func confidentLanguage(_ text: String, minConfidence: Double,
                                          constraints: [NLLanguage]) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        if !constraints.isEmpty { recognizer.languageConstraints = constraints }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let top = hypotheses.first, top.value >= minConfidence else { return nil }
        // A ten-point lead is conservative enough to keep clear prose while refusing mixed blobs where
        // Apple's close Romance-language scores make a single winner look more certain than it is.
        if hypotheses.count > 1, top.value - hypotheses[1].value < 0.10 { return nil }
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
        guard prefix.count >= 12,
              let lang = Self.dominantLanguage(
                prefix, minConfidence: 0.50,
                languageConstraints: generationSession.languageConstraints
              ) else {
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
        CompletionActivationEvaluator.lastWord(of: prefix)
    }

    // MARK: - Generation token helpers

    @discardableResult
    private func bumpGeneration() -> Int {
        generationSession.bump()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        generationSession.isCurrent(gen)
    }

    private func currentGeneration() -> Int {
        generationSession.current()
    }
}
