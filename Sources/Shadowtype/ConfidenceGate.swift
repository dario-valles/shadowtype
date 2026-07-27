// ConfidenceGate — pure, testable accumulator for suppressing low-confidence completions.
// The inference engine reports each content token's RAW top-1 probability — the model's own softmax
// peak, BEFORE the sampler chain reshapes the distribution (see InferenceEngine.sampleWithProb). This
// gate turns the stream of probabilities into two suppression decisions:
//   • firstTokenRejected — the model was already unsure on its FIRST content token (gate before any
//     render, so nothing flashes on screen).
//   • meanRejected — the RUNNING geometric-mean probability has collapsed, i.e. the model started
//     flailing mid-completion and is producing word-salad even though every structural filter passed.
//     Read PER TOKEN so the decode can be cut at the collapse point; the ghost already on screen is
//     never retracted (see CompletionCoordinator.startGeneration for that tradeoff).
// Geometric mean (exp of mean log-prob) is the natural aggregate: it is the inverse of perplexity and
// punishes a single near-zero token instead of letting a few confident tokens mask it.
import Foundation

struct ConfidenceGate {
    let firstTokenMinProb: Double
    let meanMinProb: Double

    private(set) var count = 0
    private(set) var sumLogProb = 0.0
    private(set) var firstProb: Double?

    init(firstTokenMinProb: Double, meanMinProb: Double) {
        self.firstTokenMinProb = firstTokenMinProb
        self.meanMinProb = meanMinProb
    }

    mutating func record(prob: Double, isFirst: Bool) {
        count += 1
        // Clamp away from zero so a single 0-prob token yields a large-but-finite penalty, not -inf.
        sumLogProb += Foundation.log(max(prob, 1e-6))
        if isFirst, firstProb == nil { firstProb = prob }
    }

    // Geometric mean of the recorded probabilities; 1.0 (never rejected) when nothing was recorded.
    var meanProb: Double {
        guard count > 0 else { return 1.0 }
        return Foundation.exp(sumLogProb / Double(count))
    }

    var firstTokenRejected: Bool {
        guard let p = firstProb else { return false }   // no content token yet -> don't reject
        return p < firstTokenMinProb
    }

    // Needs a SECOND sample to mean anything: with one token the geometric mean IS that token's
    // probability, so a count-of-1 check would silently re-decide the first token at the mean's (looser)
    // threshold instead of the first-token gate's. From token 2 on it measures what it is meant to —
    // whether the completion is holding together or coming apart.
    var meanRejected: Bool { count >= 2 && meanProb < meanMinProb }

    // Compact log strings (avoid leaking full precision into Diag lines).
    var firstProbString: String { firstProb.map { String(format: "%.3f", $0) } ?? "nil" }
    var meanProbString: String { String(format: "%.3f", meanProb) }
}
