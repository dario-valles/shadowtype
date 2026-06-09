// RequiredPrefix — Tier 2a (KeyType ADR-019), pure sampler primitive. While the model is required to
// reproduce a typed stem (mid-word healing), a candidate token may only be sampled if its bytes are
// prefix-compatible with the still-unsatisfied remaining stem: either the token completes part of the
// remaining stem, or it starts with the whole remaining stem and continues beyond it. Everything is
// BYTE-level so a multibyte codepoint split across tokens (CJK / Arabic / emoji) is admitted
// correctly — a String-level compare would reject a token that carries only the first byte of a
// 3-byte character. InferenceEngine masks (logit = -inf) every inadmissible candidate before
// sampling, then advances `remaining` by the emitted token.
enum RequiredPrefix {

    // Admissible iff there is no remaining stem, or the token and the remaining stem are
    // prefix-compatible in either direction. An EMPTY-byte token (EOG / a pure-control token) makes no
    // progress on the stem, so it is INADMISSIBLE while a stem is pending — otherwise the model could
    // sample end-of-generation and stop before reproducing the typed stem, leaving an empty ghost.
    static func isAdmissible(tokenBytes: ArraySlice<UInt8>, remaining: ArraySlice<UInt8>) -> Bool {
        if remaining.isEmpty { return true }
        if tokenBytes.isEmpty { return false }
        return tokenBytes.starts(with: remaining) || remaining.starts(with: tokenBytes)
    }

    // The remaining stem after a token is emitted. Only meaningful for an admissible token with a
    // non-empty `remaining`: if the token carries the whole remaining stem (or more) the stem is
    // satisfied → []; if it is a proper prefix of the remaining stem, drop the consumed bytes.
    static func advanced(remaining: [UInt8], byEmitting tokenBytes: ArraySlice<UInt8>) -> [UInt8] {
        tokenBytes.count >= remaining.count ? [] : Array(remaining.dropFirst(tokenBytes.count))
    }
}
