// ModelCatalog — the curated set of downloadable local GGUF models (FR-LM-1, FR-LM-2, FR-LM-3).
// PRD §6 large-model management. This is PURE DATA + RAM-gating logic: no networking,
// no disk I/O, no shared-file edits. The integrator reuses ModelManager (which already owns resumable
// download + SHA-256 verify) to actually fetch any entry, and wires the Settings Models pane to render
// this list — every entry is free, with a RAM warning when `ramOK(for:physicalBytes:)`
// is false, and a live model swap on selection.
//
// Honesty about checksums: `sha256` is OPTIONAL. A pinned hash is only ever set for an LFS object we
// have actually downloaded and verified ourselves (the existing default model). For the larger entries
// we ship `nil` — meaning "no pinned hash yet, skip checksum with a logged warning" — rather than
// inventing a hash we cannot stand behind. The integrator pins these at release time once verified.
import Foundation

/// FR-LM-1: one selectable local model. `Identifiable` (stable `id`) so SwiftUI/AppKit lists can key on
/// it; `Hashable` so it can back a menu/selection. Every model is free.
struct ModelCatalogEntry: Identifiable, Hashable {
    /// Stable identifier (also the SwiftPM/list key); never reuse across distinct files.
    let id: String
    /// Human-facing name shown in the Models pane.
    let name: String
    /// On-disk file name under Application Support/Shadowtype/models.
    let fileName: String
    /// HTTPS `resolve` URL of the GGUF LFS object on Hugging Face.
    let url: URL
    /// Lowercase hex SHA-256 of the LFS object, or nil when no hash is pinned yet (skip checksum,
    /// log a warning). We only ever pin hashes we have verified ourselves.
    let sha256: String?
    /// Approximate resident memory (GiB) the loaded model needs; drives the RAM gate (PRD §6).
    let approxRAMGB: Double
    /// Approximate on-disk download size (GB, 1e9). Shown next to the name in the model picker.
    let downloadGB: Double
    /// Legacy field, always false; no gate. Kept so callers/tests that still set it compile.
    let paidOnly: Bool
    /// True when the GGUF is an *instruct* model (no base/pretrained variant exists for it). Instruct
    /// models are trained to end their turn, so on a dangling or complete-looking prefix they emit
    /// end-of-turn and the ghost shows nothing — worst on non-English text (bug 3, confirmed unfixable
    /// at the sampling/prompt layer: base models continue cleanly where instruct EOGs). `recommended`
    /// prefers base over instruct, and the picker can label these so a manual pick is informed.
    /// Defaults false so only the handful of instruct entries opt in.
    var isInstruct: Bool = false
}

/// FR-LM-1/2/3: the curated catalog plus RAM-fit logic. Static-only; there is no instance state.
enum ModelCatalog {
    /// The selectable models — every entry is FREE (`paidOnly:false`). The first entry is the shipping
    /// default (its known, verified hash is kept); the rest are real, reputable Q4_K_M GGUFs from the
    /// trusted llama.cpp quant repos we already use (bartowski, mradermacher). Qwen3 entries use the
    /// *Base* (pretrained, NOT instruct) GGUFs so they continue text under the raw-prefix prompt path
    /// (no chat template) instead of chatting — same rationale as the Gemma 3 base default; Gemma E2B/
    /// E4B and the MoE entries fall back to instruct fed raw-prefix (no base GGUF exists), matching the
    /// existing Gemma 4 E2B / Llama precedent. All non-default `sha256` are `nil` until pinned at release
    /// — we do not hallucinate hashes. `downloadGB` is the verified LFS Content-Length. Ordered
    /// small→large by `approxRAMGB` so RAM-fit selection (`recommended`) reads naturally.
    static let entries: [ModelCatalogEntry] = [
        // The shipping free default. Hash + URL mirror ModelManager.default* exactly (gemma-3-1b-pt
        // Q4_K_M, ~806 MB on disk; ~1.5 GiB resident with KV cache).
        ModelCatalogEntry(
            id: "gemma-3-1b-pt-q4_k_m",
            name: "Gemma 3 1B",
            fileName: ModelManager.defaultModelFileName,
            url: ModelManager.defaultModelDownloadURL,
            sha256: ModelManager.defaultModelSHA256,
            approxRAMGB: 1.5,
            downloadGB: 0.8,   // 806 MB LFS object (verified)
            paidOnly: false
        ),
        // Qwen 3 1.7B BASE (pretrained) Q4_K_M, from mradermacher's ungated GGUF repo.
        ModelCatalogEntry(
            id: "qwen3-1.7b-base-q4_k_m",
            name: "Qwen 3 1.7B",
            fileName: "Qwen3-1.7B-Base.Q4_K_M.gguf",
            url: URL(string:
                "https://huggingface.co/mradermacher/Qwen3-1.7B-Base-GGUF/resolve/main/Qwen3-1.7B-Base.Q4_K_M.gguf")!,
            sha256: nil,
            approxRAMGB: 2.0,
            downloadGB: 1.1,   // verified Content-Length
            paidOnly: false
        ),
        // Qwen 3 4B BASE (pretrained) Q4_K_M, mradermacher.
        ModelCatalogEntry(
            id: "qwen3-4b-base-q4_k_m",
            name: "Qwen 3 4B",
            fileName: "Qwen3-4B-Base.Q4_K_M.gguf",
            url: URL(string:
                "https://huggingface.co/mradermacher/Qwen3-4B-Base-GGUF/resolve/main/Qwen3-4B-Base.Q4_K_M.gguf")!,
            sha256: nil,
            approxRAMGB: 3.5,
            downloadGB: 2.5,   // verified Content-Length (2.49 GB)
            paidOnly: false
        ),
        // NOTE: Gemma 3 4B BASE (pt) was removed from the catalog — quality bake-off testing
        // showed it REGRESSES close-language steering (Catalan → Spanish 3/4 seeds even
        // WITH the language steer, vs Gemma-1B 0/4) for 3× the size. Bigger ≠ better here.
        // Gemma 4 E2B — Google's OFFICIAL QAT Q4_0 GGUF (gemma-4-E2B-it-qat-q4_0-gguf). QAT
        // (quantization-aware training) preserves quality at Q4 far better than community PTQ Q4_K_M,
        // and ships smaller (3.35 vs 3.46 GB). MatFormer "effective-2B" on-device model. Still INSTRUCT
        // (no base/QAT-base variant exists) — fed raw-prefix, so EOG-prone and deprioritized vs Qwen
        // base. Multimodal mmproj file exists in the repo but is not needed for text completion.
        // sha256 nil until self-downloaded + verified at release.
        ModelCatalogEntry(
            id: "gemma-4-e2b-it-qat-q4_0",
            name: "Gemma 4 E2B",
            fileName: "gemma-4-E2B_q4_0-it.gguf",
            url: URL(string:
                "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf")!,
            sha256: nil,
            approxRAMGB: 4.4,
            downloadGB: 3.35,  // verified file size (Google QAT Q4_0)
            paidOnly: false,
            isInstruct: true
        ),
        // Gemma 4 E4B — Google's OFFICIAL QAT Q4_0 GGUF. Larger MatFormer "effective-4B"; fed
        // raw-prefix. Smaller than the old bartowski Q4_K_M (5.15 vs 5.40 GB) at higher fidelity.
        ModelCatalogEntry(
            id: "gemma-4-e4b-it-qat-q4_0",
            name: "Gemma 4 E4B",
            fileName: "gemma-4-E4B_q4_0-it.gguf",
            url: URL(string:
                "https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf/resolve/main/gemma-4-E4B_q4_0-it.gguf")!,
            sha256: nil,
            approxRAMGB: 6.3,
            downloadGB: 5.15,  // verified file size (Google QAT Q4_0)
            paidOnly: false,
            isInstruct: true
        ),
        // Qwen 3 8B BASE (pretrained) Q4_K_M, mradermacher.
        ModelCatalogEntry(
            id: "qwen3-8b-base-q4_k_m",
            name: "Qwen 3 8B",
            fileName: "Qwen3-8B-Base.Q4_K_M.gguf",
            url: URL(string:
                "https://huggingface.co/mradermacher/Qwen3-8B-Base-GGUF/resolve/main/Qwen3-8B-Base.Q4_K_M.gguf")!,
            sha256: nil,
            approxRAMGB: 6.8,
            downloadGB: 5.0,   // verified Content-Length (5.02 GB)
            paidOnly: false
        ),
        // Meta Llama 3.1 8B Instruct, bartowski. Fed raw-prefix. Hash pinned at release.
        ModelCatalogEntry(
            id: "llama-3.1-8b-instruct-q4_k_m",
            name: "Llama 3.1 8B Instruct",
            fileName: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            url: URL(string:
                "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf")!,
            sha256: nil,
            approxRAMGB: 7.5,
            downloadGB: 4.9,   // approximate; pinned at release
            paidOnly: false,
            isInstruct: true
        ),
        // Gemma 4 12B — Google's OFFICIAL QAT Q4_0 GGUF (released 2026-06-03). Dense, encoder-free
        // multimodal; bridges the gap between E4B (~6 GB) and the 26B MoE (~16 GB) that the catalog
        // previously jumped over. Fed raw-prefix (instruct). sha256 nil until pinned at release.
        ModelCatalogEntry(
            id: "gemma-4-12b-it-qat-q4_0",
            name: "Gemma 4 12B",
            fileName: "gemma-4-12b-it-qat-q4_0.gguf",
            url: URL(string:
                "https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf/resolve/main/gemma-4-12b-it-qat-q4_0.gguf")!,
            sha256: nil,
            approxRAMGB: 8.5,
            downloadGB: 6.98,  // verified file size (Google QAT Q4_0)
            paidOnly: false,
            isInstruct: true
        ),
        // Gemma 4 26B-A4B — Google's OFFICIAL QAT Q4_0 GGUF. Sparse MoE (~26B total / ~4B active).
        // Big: all weights resident, so RAM-gated into "Other models" on most Macs. QAT Q4_0 is
        // smaller than the old bartowski Q4_K_M (14.4 vs 17.0 GB). Fed raw-prefix. STILL verify this
        // MoE arch loads in the shipped llama.cpp build before pinning a hash (see plan risks).
        ModelCatalogEntry(
            id: "gemma-4-26b-a4b-it-qat-q4_0",
            name: "Gemma 4 26B A4B",
            fileName: "gemma-4-26B_q4_0-it.gguf",
            url: URL(string:
                "https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/main/gemma-4-26B_q4_0-it.gguf")!,
            sha256: nil,
            approxRAMGB: 15.8,
            downloadGB: 14.4,  // verified file size (Google QAT Q4_0)
            paidOnly: false,
            isInstruct: true
        ),
        // Qwen 3 30B-A3B BASE (pretrained) — sparse MoE (~30B total / ~3B active), mradermacher.
        // Largest entry; RAM-gated into "Other models" except on high-RAM Macs.
        ModelCatalogEntry(
            id: "qwen3-30b-a3b-base-q4_k_m",
            name: "Qwen 3 30B A3B",
            fileName: "Qwen3-30B-A3B-Base.Q4_K_M.gguf",
            url: URL(string:
                "https://huggingface.co/mradermacher/Qwen3-30B-A3B-Base-GGUF/resolve/main/Qwen3-30B-A3B-Base.Q4_K_M.gguf")!,
            sha256: nil,
            approxRAMGB: 20.0,
            downloadGB: 18.6,  // verified Content-Length (18.55 GB)
            paidOnly: false
        ),
    ]

    /// FR-LM-2 (PRD §6): a model is RAM-OK only if its approximate footprint stays within ~75% of
    /// physical RAM. Beyond that the Models pane warns/blocks (loading would thrash or OOM). Uses GB
    /// (1e9) to match the human-facing `approxRAMGB` figures. `physicalBytes` is injectable so tests can
    /// pass synthetic machine sizes (no `ProcessInfo` dependency here).
    static func ramOK(for entry: ModelCatalogEntry, physicalBytes: UInt64) -> Bool {
        let needed = entry.approxRAMGB * 1e9
        let budget = 0.75 * Double(physicalBytes)
        return needed <= budget
    }

    /// FR-LM-3: the best default for this machine — the largest entry that comfortably fits in RAM,
    /// falling back to the smallest entry when nothing fits (so we always return something to load).
    /// "Largest/smallest" is by `approxRAMGB`. `entries` is guaranteed non-empty. Every model is free,
    /// so the whole catalog is always a candidate.
    static func recommended(physicalBytes: UInt64) -> ModelCatalogEntry {
        let candidates = entries
        let fitting = candidates.filter { ramOK(for: $0, physicalBytes: physicalBytes) }
        // Prefer the largest BASE model that fits. Base (pretrained) models continue raw-prefix text
        // reliably; instruct models emit end-of-turn on dangling/complete-looking prefixes and silently
        // drop the ghost (bug 3 — proven unfixable at the sampling layer). Picking the biggest-that-fits
        // regardless of kind steered high-RAM Macs onto instruct models (e.g. Llama-3.1-8B-Instruct over
        // the near-identical-size Qwen3-8B-Base), trading ghost-correctness for a fraction of a GB.
        if let bestBase = fitting.filter({ !$0.isInstruct }).max(by: { $0.approxRAMGB < $1.approxRAMGB }) {
            return bestBase
        }
        // No base fits (only instruct models small enough): take the largest instruct that fits.
        if let best = fitting.max(by: { $0.approxRAMGB < $1.approxRAMGB }) {
            return best
        }
        // Nothing fits the 75% budget: pick the smallest available so the app still has a model to run.
        return candidates.min(by: { $0.approxRAMGB < $1.approxRAMGB }) ?? entries[0]
    }
}
