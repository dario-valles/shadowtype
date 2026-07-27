// ModelCatalog — the curated set of downloadable local GGUF models (FR-LM-1, FR-LM-2, FR-LM-3).
// PRD §6 large-model management. This is PURE DATA + RAM-gating logic: no networking,
// no disk I/O, no shared-file edits. The integrator reuses ModelManager (which already owns resumable
// download + SHA-256 verify) to actually fetch any entry, and wires the Settings Models pane to render
// this list — every entry is free, with a RAM warning when `ramOK(for:physicalBytes:)`
// is false, and a live model swap on selection.
//
// Honesty about checksums: `sha256` is OPTIONAL. A pinned hash is only ever set for an LFS object we
// have actually downloaded and verified ourselves (the existing default model); for the larger entries
// we ship `nil` rather than inventing a hash we cannot stand behind. `nil` no longer means "unchecked":
// ModelManager falls back to the SHA-256 Hugging Face reports for the LFS object (`X-Linked-Etag`) and
// only drops to a GGUF-magic sanity check when that header is absent — and it reports which of the
// three happened via `lastVerification`, so the UI never overclaims.
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
    /// Lowercase hex SHA-256 of the LFS object, or nil when no hash is pinned yet — in which case
    /// ModelManager verifies against the server-reported `X-Linked-Etag` instead. We only ever pin
    /// hashes we have verified ourselves; a pin always WINS over the header (see verificationPlan).
    let sha256: String?
    /// Approximate resident memory (GiB) the loaded model needs; drives the RAM gate (PRD §6).
    let approxRAMGB: Double
    /// Approximate on-disk download size (GB, 1e9). Shown next to the name in the model picker.
    let downloadGB: Double
    /// Legacy field, always false; no gate. Kept so callers/tests that still set it compile.
    let paidOnly: Bool
    /// Quantization format of THIS file, read off its actual filename ("Q4_K_M", "Q4_0"), or nil when
    /// unknown (BYOM imports, whose filename is the user's). The model cards used to hardcode "Q4_K_M"
    /// for every row, which mislabeled the four Google QAT `q4_0` GGUFs; the UI must render this field
    /// instead of a constant. Declared after `paidOnly` so the memberwise init keeps its existing
    /// argument order for the call sites that don't set it (ImportedModelStore, tests).
    var quant: String? = nil
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
    /// default (its known, verified hash is kept); the rest are real, reputable GGUFs from trusted
    /// sources — community Q4_K_M re-quants (mradermacher) and Google's own QAT `q4_0` builds. Each
    /// entry records its actual format in `quant`; do not assume Q4_K_M. Qwen3 entries use the
    /// *Base* (pretrained, NOT instruct) GGUFs so they continue text under the raw-prefix prompt path
    /// (no chat template) instead of chatting — same rationale as the Gemma 3 base default; the Gemma 4
    /// entries fall back to instruct fed raw-prefix because no base GGUF exists for them at all.
    /// All non-default `sha256` are `nil` until pinned at release
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
            paidOnly: false,
            quant: "Q4_K_M"
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
            paidOnly: false,
            quant: "Q4_K_M"
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
            paidOnly: false,
            quant: "Q4_K_M"
        ),
        // NOTE: Gemma 3 4B BASE (pt) was removed from the catalog — quality bake-off testing
        // showed it REGRESSES close-language steering (Catalan → Spanish 3/4 seeds even
        // WITH the language steer, vs Gemma-1B 0/4) for 3× the size. Bigger ≠ better here.
        //
        // CAVEAT on the four `gemma-4-*-qat-q4_0` entries below (E2B, E4B, 12B, 26B-A4B): they are
        // Q4_0 GGUFs *published from* QAT checkpoints, and a naive Q4_0 conversion from a QAT
        // checkpoint throws most of the QAT benefit away — llama.cpp's Q4_0 stores F16 block scales
        // while the QAT recipe trains against BF16 scales, so the trained scales are re-rounded.
        // Vendor-published figures for that mismatch are ~70.2% vs ~85.6% top-1 (their numbers, NOT
        // independently confirmed by us). We have NOT verified which conversion path produced these
        // specific files, so the URLs stay as-is; if a Gemma 4 entry ever reads noticeably worse than
        // its size suggests, re-quantize from the QAT checkpoint with BF16 scales and compare before
        // blaming the prompt path.
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
            quant: "Q4_0",
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
            quant: "Q4_0",
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
            paidOnly: false,
            quant: "Q4_K_M"
        ),
        // NOTE: Meta Llama 3.1 8B Instruct was removed — it was dominated on every axis a catalog entry
        // has to earn: beaten by ~4B-class 2026 models while being twice their size, a 2023-12
        // knowledge cutoff, the only non-Apache/permissive license in an otherwise clean catalog, and
        // the only instruct entry that broke the base-variant-for-raw-continuation rule by choice (the
        // Gemma 4 entries are instruct only because no base GGUF exists for them; a Llama 3.1 8B base
        // does exist). Its approxRAMGB (7.5) also sat ABOVE qwen3-8b-base's 6.8 despite a SMALLER
        // download, so it sorted last and `recommended` skipped it as instruct — it could only ever be
        // reached by a mis-click.
        //
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
            quant: "Q4_0",
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
            quant: "Q4_0",
            isInstruct: true
        ),
        // Qwen 3 30B-A3B BASE (pretrained) — sparse MoE (~30B total / ~3B active), mradermacher.
        // Largest entry; RAM-gated into "Other models" except on high-RAM Macs. Never recommended
        // (see `recommendedCapRAMGB`) — it exists for the local API / manual power-user pick, where
        // there is no 400 ms ghost deadline to miss.
        ModelCatalogEntry(
            id: "qwen3-30b-a3b-base-q4_k_m",
            name: "Qwen 3 30B A3B",
            fileName: "Qwen3-30B-A3B-Base.Q4_K_M.gguf",
            url: URL(string:
                "https://huggingface.co/mradermacher/Qwen3-30B-A3B-Base-GGUF/resolve/main/Qwen3-30B-A3B-Base.Q4_K_M.gguf")!,
            sha256: nil,
            approxRAMGB: 20.0,
            downloadGB: 18.6,  // verified Content-Length (18.55 GB)
            paidOnly: false,
            quant: "Q4_K_M"
        ),
    ]

    /// GB (1e9) macOS itself plus whatever app the user is typing into needs to stay resident. The
    /// budget used to be a flat 75% of RAM, which on an 8 GB Mac left 6.44 GB for the model and nothing
    /// for the system — so the 6.3 GB E4B entry reported RAM-OK and never got the "Tight on RAM" tag,
    /// while in practice it swaps. On Apple Silicon the GPU draws from this SAME unified pool, so there
    /// is no separate VRAM to fall back on.
    private static let osReserveGB = 3.0

    /// Fraction of `approxRAMGB` to add for the F16 KV cache at the engine's n_ctx = 4096
    /// (InferenceEngine.contextSize). KV bytes are 2 · n_layer · n_kv_head · head_dim · 2 at F16, which
    /// tracks model size closely enough for a gate: measured ≈0.11 GB for Gemma-3-1B (1.5 GB weights)
    /// and ≈0.60 GB for Qwen3-8B (6.8 GB weights) — both ≈8%. 10% is the conservative round number.
    /// Deliberately a ratio and not a per-model table: this is a warning threshold, not an allocator.
    private static let kvCacheFraction = 0.10

    /// FR-LM-2 (PRD §6): a model is RAM-OK only if its WEIGHTS PLUS KV CACHE fit the machine's budget,
    /// where the budget is the tighter of ~75% of physical RAM (the original headroom rule, binding on
    /// big Macs) and "everything except the OS floor" (binding on 8 GB Macs). Beyond that the Models
    /// pane warns. Uses GB (1e9) to match the human-facing `approxRAMGB` figures. `physicalBytes` is
    /// injectable so tests can pass synthetic machine sizes (no `ProcessInfo` dependency here).
    static func ramOK(for entry: ModelCatalogEntry, physicalBytes: UInt64) -> Bool {
        let physicalGB = Double(physicalBytes) / 1e9
        let needed = entry.approxRAMGB * (1.0 + kvCacheFraction)
        let budget = min(0.75 * physicalGB, physicalGB - osReserveGB)
        return needed <= budget
    }

    /// Largest `approxRAMGB` the RECOMMENDATION will ever pre-select, by machine class. This is a
    /// deliberate product decision, not a bug fix — do NOT "optimize" it back to largest-that-fits.
    ///
    /// Shadowtype is a LATENCY product: the coordinator drops the ghost if the first token misses its
    /// ~400 ms deadline on a ~1500-token prompt. A 30B MoE cannot clear that deadline, so on a 32 GB
    /// Mac the old "largest that fits" rule pre-selected an 18.6 GB download that then showed NO ghost
    /// at all — the product reads as broken. The objective is "best quality that clears the first-token
    /// deadline", not "largest that fits".
    /// Bigger is also not reliably better on quality here: see the Gemma 3 4B note above — the 4B base
    /// REGRESSED Catalan→Spanish steering (3/4 seeds vs the 1B's 0/4) at 3× the size, which is why it
    /// was removed from the catalog outright.
    /// The large entries stay in the catalog and stay manually selectable — someone driving the local
    /// API off a 30B has no ghost deadline to miss.
    ///
    /// >= 16 GB: the 4B class (qwen3-4b-base, 3.5 GB). Below that: the ~1.5 GB class (Gemma 3 1B) —
    /// an 8 GB Mac is already sharing unified memory with the browser or editor being typed into, and
    /// a swapping model misses the deadline just as surely as a slow one.
    static func recommendedCapRAMGB(physicalBytes: UInt64) -> Double {
        Double(physicalBytes) >= 16e9 ? 3.5 : 1.5
    }

    /// FR-LM-3: the best default for this machine — the largest entry that both fits in RAM and stays
    /// under `recommendedCapRAMGB` (the first-token-deadline cap), falling back to the smallest entry
    /// when nothing qualifies (so we always return something to load). "Largest/smallest" is by
    /// `approxRAMGB`. `entries` is guaranteed non-empty. Every model is free, so the whole catalog is
    /// always a candidate.
    static func recommended(physicalBytes: UInt64) -> ModelCatalogEntry {
        let candidates = entries
        let cap = recommendedCapRAMGB(physicalBytes: physicalBytes)
        let fitting = candidates.filter {
            $0.approxRAMGB <= cap && ramOK(for: $0, physicalBytes: physicalBytes)
        }
        // Prefer the largest BASE model under the cap. Base (pretrained) models continue raw-prefix text
        // reliably; instruct models emit end-of-turn on dangling/complete-looking prefixes and silently
        // drop the ghost (bug 3 — proven unfixable at the sampling layer). Picking the biggest-that-fits
        // regardless of kind steered high-RAM Macs onto instruct models (e.g. the removed
        // Llama-3.1-8B-Instruct over the near-identical-size Qwen3-8B-Base), trading ghost-correctness
        // for a fraction of a GB.
        if let bestBase = fitting.filter({ !$0.isInstruct }).max(by: { $0.approxRAMGB < $1.approxRAMGB }) {
            return bestBase
        }
        // No base qualifies (only instruct models are small enough): take the largest instruct.
        if let best = fitting.max(by: { $0.approxRAMGB < $1.approxRAMGB }) {
            return best
        }
        // Nothing clears the RAM budget at all (a machine below the OS floor + smallest model): pick the
        // smallest entry so the app still has a model to run, knowingly over budget.
        return candidates.min(by: { $0.approxRAMGB < $1.approxRAMGB }) ?? entries[0]
    }
}
