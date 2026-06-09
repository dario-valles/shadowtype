// OverlayRefireDecision — pure decision for what to do with a streamed token (or final
// generation buffer) during a context-driven re-fire whose visible ghost should be held.
//
// Why this exists: a re-fire fires a new generation while a ghost is already on screen, hoping
// it produces the SAME text (a silent re-confirmation) or a strict EXTENSION (longer
// completion to commit). When the new generation produces something DIVERGENT — neither a
// prefix of the visible ghost nor extended from it — replacing the visible ghost mid-pause is
// the dominant flicker the user experiences ("ghost A → ghost B" while paused). This gate
// keeps the re-fire strictly monotonic: hold or extend, never replace.
import Foundation

enum OverlayRefireDecision {
    enum Action: Equatable {
        case hold              // new stream is a prefix of the visible ghost (or both empty) — silently hold the existing ghost
        case renderExtension   // visible is a strict prefix of the new stream — commit the longer text
        case discard           // divergent (neither is a prefix of the other) — silently drop, keep the visible ghost
    }

    // Decide what the streaming closure (or gen-done flush) should do with `snapshot`, given the
    // currently-visible `visible` suggestion. Pure + testable.
    //
    // Semantics:
    // - empty visible → discard (no ghost to hold; the caller should fall through to normal render)
    // - empty snapshot → hold (nothing to render; the visible ghost is untouched)
    // - snapshot == visible → hold (model is regenerating the same text)
    // - snapshot is a strict prefix of visible → hold (mid-stream still building toward the held text)
    // - visible is a strict prefix of snapshot → renderExtension (model is extending the ghost)
    // - otherwise → discard (divergent; replacing would flicker)
    static func decide(visible: String, snapshot: String) -> Action {
        if visible.isEmpty { return .discard }
        if snapshot.isEmpty { return .hold }
        if snapshot == visible { return .hold }
        if visible.hasPrefix(snapshot) { return .hold }
        if snapshot.hasPrefix(visible) { return .renderExtension }
        return .discard
    }
}
