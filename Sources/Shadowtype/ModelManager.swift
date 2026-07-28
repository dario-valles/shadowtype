// ModelManager — resolves, downloads, and verifies the default local GGUF model.
// PRD §6: the model is NEVER bundled; it is fetched on first run into Application Support.
import Foundation
import CryptoKit

enum ModelManagerError: LocalizedError {
    case appSupportUnavailable
    case downloadFailed(underlying: Error)
    case serverError(statusCode: Int)
    case noDownloadedFile
    case checksumMismatch(expected: String, actual: String)
    case invalidModelFile(String)
    case insufficientDiskSpace(neededGB: Double, availableGB: Double)
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .appSupportUnavailable:
            return "Could not locate the Application Support directory to store the model."
        case .downloadFailed(let underlying):
            return "Model download failed: \(underlying.localizedDescription)"
        case .serverError(let statusCode):
            return "Model download failed: server returned HTTP \(statusCode)."
        case .noDownloadedFile:
            return "Model download completed but the temporary file was missing."
        case .checksumMismatch(let expected, let actual):
            return "Model checksum mismatch (expected \(expected), got \(actual)). The file is corrupt or incomplete."
        case .invalidModelFile(let id):
            return "Downloaded model \(id) is not a valid GGUF file (corrupt, truncated, or not a model)."
        case .insufficientDiskSpace(let neededGB, let availableGB):
            return String(format: "Not enough disk space (need %.1f GB, %.1f GB available).",
                          neededGB, availableGB)
        case .sizeMismatch(let expected, let actual):
            return "Model download is incomplete (expected \(expected) bytes, got \(actual))."
        }
    }
}

/// What actually vouched for the bytes of the most recent download (FR-LM-2).
///
/// The onboarding copy told every user their model was "verified by checksum" while 9 of 11 catalog
/// entries ship `sha256: nil` — for those the only check was the 4-byte GGUF magic, which a truncated
/// or tampered multi-GB file passes trivially. The UI reads this to say what really happened.
enum ModelVerification: Equatable {
    /// Every byte hashed to the catalog's hand-pinned SHA-256.
    case pinnedSHA256
    /// Every byte hashed to the SHA-256 Hugging Face reports for the LFS object (`X-Linked-Etag`).
    case linkedSHA256
    /// No hash was available to check against (no pin, and no usable `X-Linked-Etag`): GGUF magic
    /// only, plus the byte count when `X-Linked-Size` was present.
    case unverified

    /// True when a full SHA-256 over every byte matched — i.e. "verified by checksum" is honest.
    var isHashVerified: Bool { self != .unverified }
}

final class ModelManager {
    private static let activeTransfers = ActiveTransferRegistry()
    // Base (pretrained, NOT instruct) gemma-3-1b, Q4_K_M. Comparison testing
    // showed the instruct model fails autocomplete *semantically* — it answers as an assistant
    // (multiple-choice replies, meta-commentary, "[Insert name]" templates) right at the first token,
    // which no output filter can fix. The base model continues text naturally and gets the immediate
    // next word right far more often; its only artifacts are cosmetic web markup (HTML/markdown),
    // which the coordinator's output sanitizer strips. Raw-prefix prompting also preserves the
    // engine's KV-cache prefix-growth warm path (FR-CE-5), which chat-template wrapping would destroy.
    static let defaultModelFileName = "gemma-3-1b-pt-Q4_K_M.gguf"
    static let defaultModelDownloadURL = URL(string:
        "https://huggingface.co/mradermacher/gemma-3-1b-pt-GGUF/resolve/main/gemma-3-1b-pt.Q4_K_M.gguf")!
    // sha256 of the LFS object (resolved 2026-06-01). size 806056864 bytes.
    static let defaultModelSHA256 = "caf1c278f8a8ba1e4605af68b6c17c91a18bf315b38bd52efc542d009d19dd57"

    /// UserDefaults key persisting the user's selected model id (FR-LM-1). The Models pane picker
    /// writes it; AppDelegate reads it at launch to reload the chosen model instead of the default.
    static let selectedModelDefaultsKey = "shadowtype.selectedModelID"

    /// Progress callback: fraction in 0...1, or nil while total size is unknown.
    var onDownloadProgress: ((Double?) -> Void)?

    /// How the most recent download was verified, or nil when this call downloaded nothing (the file
    /// was already on disk). Exposed so the onboarding/Models UI states the truth instead of claiming
    /// every model is "verified by checksum" — see `ModelVerification`.
    private(set) var lastVerification: ModelVerification?

    enum VerificationEvent: Equatable {
        case willVerify(staging: URL, destination: URL)
        case didVerify(staging: URL, destination: URL)
        case didPromote(destination: URL)
    }

    private let sessionConfiguration: URLSessionConfiguration
    private let modelsDirectoryOverride: URL?
    private let availableCapacity: ((URL) -> Int64?)?
    private let huggingFaceToken: () -> String?
    private let onVerificationEvent: ((VerificationEvent) -> Void)?

    init(sessionConfiguration: URLSessionConfiguration = .default,
         modelsDirectory: URL? = nil,
         availableCapacity: ((URL) -> Int64?)? = nil,
         huggingFaceToken: @escaping () -> String? = {
             APIKeyStore.read(.huggingfaceToken)
         },
         onVerificationEvent: ((VerificationEvent) -> Void)? = nil) {
        self.sessionConfiguration = sessionConfiguration
        self.modelsDirectoryOverride = modelsDirectory
        self.availableCapacity = availableCapacity
        self.huggingFaceToken = huggingFaceToken
        self.onVerificationEvent = onVerificationEvent
    }

    /// Called from the app-termination path before process exit. Cancellation persists each transfer's
    /// resumable state before this returns (or the timeout expires).
    @discardableResult
    static func cancelActiveTransfersAndWait(timeout: TimeInterval = 3) -> Bool {
        activeTransfers.cancelAllAndWait(timeout: timeout)
    }

    func defaultModelURL() -> URL {
        return modelsDirectory().appendingPathComponent(Self.defaultModelFileName)
    }

    // The default free model as a catalog entry: ensureDefaultModel() is just ensureModel(entries[0]),
    // since ModelCatalog.entries[0] mirrors default* exactly. Kept as a named method so existing call
    // sites (AppDelegate launch, smoke/bench) are unchanged.
    func ensureDefaultModel() async throws -> URL {
        try await ensureModel(ModelCatalog.entries[0])
    }

    /// FR-LM-1: resolve the model to load at launch. Honors the user's persisted choice ONLY when it
    /// is already downloaded — we never start a multi-GB download during launch. Anything else falls
    /// back to the small default.
    func ensureStartupModel() async throws -> URL {
        let id = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey)
        // M3 BYOM: persisted selection might be an imported model. Load it directly (no download),
        // falling through to the curated catalog or default if the import is missing/broken.
        if let id, id.hasPrefix("byom-"),
           let imported = ImportedModelStore.shared.find(id: id),
           FileManager.default.fileExists(atPath: imported.linkedPath) {
            let target = URL(fileURLWithPath: imported.linkedPath)
            if imported.source == .localFile || Self.hasValidVerificationReceipt(for: target) {
                return target
            }
        }
        if let id, id != ModelCatalog.entries[0].id,
           let entry = ModelCatalog.entries.first(where: { $0.id == id }),
           FileManager.default.fileExists(atPath: modelURL(for: entry).path) {
            return try await ensureModel(entry)   // present on disk → returns immediately, no download
        }
        // The selection names a catalog entry that no longer exists (an id retired between releases —
        // llama-3.1-8b-instruct was dropped in the 2026-07 catalog pass). Runtime already falls through
        // safely, but leaving the dead id in defaults desynchronizes the Models pane: `selectedEntry`
        // falls back to entries[0] and reports it Loaded, while every row's `entry.id == selectedID`
        // check is false, so NO row shows the Active pill and the loaded model still offers "Use". Clear
        // it so @AppStorage resolves to entries[0] and the pane agrees with itself again.
        if let id, !id.hasPrefix("byom-"), !ModelCatalog.entries.contains(where: { $0.id == id }) {
            UserDefaults.standard.removeObject(forKey: Self.selectedModelDefaultsKey)
        }
        return try await ensureDefaultModel()
    }

    /// On-disk URL for an arbitrary catalog entry (Application Support/Shadowtype/models/<fileName>).
    /// Exposed so the Settings Models pane can show per-entry download/installed state.
    /// M3 BYOM: an imported entry (id prefix `byom-`) routes to its symlink instead — those
    /// already live under models/imported/ pointing at the user's original .gguf.
    func modelURL(for entry: ModelCatalogEntry) -> URL {
        if entry.id.hasPrefix("byom-"),
           let imported = ImportedModelStore.shared.find(id: entry.id) {
            return URL(fileURLWithPath: imported.linkedPath)
        }
        return modelsDirectory().appendingPathComponent(entry.fileName)
    }

    /// FR-LM-1/2: download (resumable) + SHA-verify any catalog entry, reusing the same download/hash
    /// code as the default model. Returns early if the file is already present. A pinned `entry.sha256`
    /// wins; otherwise the SHA-256 Hugging Face reports for the LFS object (`X-Linked-Etag`, read off
    /// the request we already make) is used, so entries with no pinned hash are still verified. Only
    /// when neither exists do we fall back to the GGUF-magic check — and `lastVerification` then says
    /// `.unverified` so the UI stops claiming a checksum was validated.
    @discardableResult
    func ensureModel(_ entry: ModelCatalogEntry) async throws -> URL {
        // M3 BYOM: imported entries live as local symlinks; no download/verify path. The import
        // flow already validated the GGUF magic before persisting the entry, and re-validating on
        // every load would re-read every byte of a multi-GB file — too expensive. Trust the
        // import's prior validation; engine.load surfaces any post-hoc corruption.
        if entry.id.hasPrefix("byom-") {
            let target = modelURL(for: entry)
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw ModelManagerError.invalidModelFile(entry.id)
            }
            if let imported = ImportedModelStore.shared.find(id: entry.id),
               imported.source == .huggingFace,
               !Self.hasValidVerificationReceipt(for: target) {
                throw ModelManagerError.invalidModelFile(entry.id)
            }
            lastVerification = nil
            return target
        }
        let destination = modelURL(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            lastVerification = nil   // nothing was downloaded: don't report a stale verdict
            if Self.hasValidVerificationReceipt(for: destination, id: entry.id,
                                                source: entry.url, pinnedSHA256: entry.sha256) {
                return destination
            }
            NSLog("[Shadowtype] WARNING: cached model \(entry.id) has no valid verification receipt; "
                  + "re-downloading")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: Self.verificationReceiptURL(for: destination))
        }
        try FileManager.default.createDirectory(at: modelsDirectory(),
                                                withIntermediateDirectories: true)
        // Disk-space preflight: fail fast with an actionable message instead of letting a multi-GB
        // download die mid-flight (or fill the volume). Surfaces through the same error path as any
        // other download failure (.shadowtypeModelDidChange userInfo["error"]).
        try preflightDiskSpace(neededBytes: Int64(entry.downloadGB * 1e9),
                               at: destination.deletingLastPathComponent())
        let result = try await download(from: entry.url, to: destination)
        lastVerification = try verifyAndPromote(result, to: destination, id: entry.id,
                                                source: entry.url, pinnedSHA256: entry.sha256)
        return destination
    }

    /// Check the freshly-written bytes and report what actually vouched for them. Deletes the file and
    /// throws on ANY mismatch — a bad multi-GB file must never reach engine.load, nor be reused as a
    /// cached download forever. Ordered cheapest-first: 4-byte magic, then the byte count, then the
    /// full hash (which re-reads the file in 1 MiB chunks — never all at once).
    private struct VerificationEvidence {
        let outcome: ModelVerification
        let expectedSHA256: String?
        let actualSHA256: String?
    }

    private func verifyDownloaded(_ staged: URL, id: String,
                                  pinnedSHA256: String?, result: DownloadResult) throws -> VerificationEvidence {
        // An HTML error page or an aborted transfer that still produced a file: reject before spending
        // a full-file read on hashing it.
        guard Self.isValidGGUF(staged) else {
            try? FileManager.default.removeItem(at: staged)
            throw ModelManagerError.invalidModelFile(id)
        }
        // Truncation is the common real-world failure and it sails past the magic check, so compare the
        // byte count against `X-Linked-Size` whenever the server gave us one.
        if let expectedSize = result.linkedSize {
            let actualSize = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size]
                              as? NSNumber)?.int64Value ?? -1
            do {
                try Self.checkDownloadedSize(expected: expectedSize, actual: actualSize)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
        }
        let plan = Self.verificationPlan(pinnedSHA256: pinnedSHA256, linkedSHA256: result.linkedSHA256)
        var actualSHA256: String?
        if let expected = plan.expected {
            let actual = (try? sha256Hex(of: staged)) ?? "<unreadable>"
            actualSHA256 = actual
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: staged)
                throw ModelManagerError.checksumMismatch(expected: expected, actual: actual)
            }
        } else {
            NSLog("[Shadowtype] WARNING: \(id) has no pinned SHA-256 and the server sent no usable "
                  + "X-Linked-Etag; verified GGUF magic only — NOT hash-verified")
        }
        return VerificationEvidence(outcome: plan.outcome,
                                    expectedSHA256: plan.expected,
                                    actualSHA256: actualSHA256)
    }

    /// Pure decision: which hash the downloaded bytes must match, and what a match proves.
    /// A catalog-pinned hash always wins over the server-reported one — the pin is the value we
    /// audited ourselves, so if Hugging Face ever serves different bytes under the same URL that has
    /// to be a hard failure, not a silently-accepted "the header agrees with itself".
    static func verificationPlan(pinnedSHA256: String?,
                                 linkedSHA256: String?) -> (expected: String?, outcome: ModelVerification) {
        if let pinned = pinnedSHA256, !pinned.isEmpty { return (pinned, .pinnedSHA256) }
        if let linked = linkedSHA256, !linked.isEmpty { return (linked, .linkedSHA256) }
        return (nil, .unverified)
    }

    /// Pure size gate, split out so it's unit-testable without a download.
    static func checkDownloadedSize(expected: Int64, actual: Int64) throws {
        guard expected != actual else { return }
        throw ModelManagerError.sizeMismatch(expected: expected, actual: actual)
    }

    /// Hugging Face reports the LFS object's real SHA-256 in `X-Linked-Etag` (quoted, occasionally with
    /// a weak-validator prefix). Anything that is not exactly 64 ASCII hex chars is NOT a content hash
    /// — small non-LFS files get an arbitrary/md5-shaped ETag — so reject it rather than "verify"
    /// against a value that can never match. Pure + testable.
    static func parseLinkedSHA256(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("W/") { s.removeFirst(2) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard s.count == 64, s.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return s.lowercased()
    }

    /// `X-Linked-Size` is the LFS object's byte count. Pure + testable.
    static func parseLinkedSize(_ raw: String?) -> Int64? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let n = Int64(s), n > 0 else { return nil }
        return n
    }

    // Cheap integrity gate for nil-hash models: a real GGUF begins with the 4-byte ASCII magic "GGUF".
    // Reading 4 bytes is O(1) regardless of the multi-GB file size, so it's safe on the cached-reuse path.
    static func isValidGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        return magic == Data([0x47, 0x47, 0x55, 0x46])   // "GGUF"
    }

    private struct VerificationReceipt: Codable {
        static let currentVersion = 1

        let version: Int
        let modelID: String
        let source: String
        let pinnedSHA256: String?
        let expectedSHA256: String?
        let actualSHA256: String?
        let outcome: String
        let fileSize: Int64
        let modificationNanoseconds: Int64
    }

    static func verificationReceiptURL(for destination: URL) -> URL {
        destination.appendingPathExtension("verified.json")
    }

    private static func fileIdentity(at url: URL) -> (size: Int64, modified: Int64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (size, Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()))
    }

    private static func hasValidVerificationReceipt(for destination: URL, id: String,
                                                     source: URL, pinnedSHA256: String?) -> Bool {
        guard let receipt = validVerificationReceipt(for: destination),
              receipt.modelID == id,
              receipt.source == resumeSourceIdentity(source),
              receipt.pinnedSHA256?.lowercased() == pinnedSHA256?.lowercased() else { return false }
        return true
    }

    private static func hasValidVerificationReceipt(for destination: URL) -> Bool {
        validVerificationReceipt(for: destination) != nil
    }

    private static func validVerificationReceipt(for destination: URL) -> VerificationReceipt? {
        guard let data = try? Data(contentsOf: verificationReceiptURL(for: destination)),
              let receipt = try? JSONDecoder().decode(VerificationReceipt.self, from: data),
              receipt.version == VerificationReceipt.currentVersion,
              let identity = fileIdentity(at: destination),
              identity.size == receipt.fileSize,
              identity.modified == receipt.modificationNanoseconds else { return nil }
        if let expected = receipt.expectedSHA256 {
            guard receipt.actualSHA256?.caseInsensitiveCompare(expected) == .orderedSame else {
                return nil
            }
        } else if receipt.outcome != "unverified" {
            return nil
        }
        return receipt
    }

    private func verifyAndPromote(_ result: DownloadResult, to destination: URL, id: String,
                                  source: URL, pinnedSHA256: String?) throws -> ModelVerification {
        onVerificationEvent?(.willVerify(staging: result.stagingURL, destination: destination))
        let evidence = try verifyDownloaded(result.stagingURL, id: id,
                                            pinnedSHA256: pinnedSHA256, result: result)
        onVerificationEvent?(.didVerify(staging: result.stagingURL, destination: destination))
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination,
                                                          withItemAt: result.stagingURL)
            } else {
                try FileManager.default.moveItem(at: result.stagingURL, to: destination)
            }
            onVerificationEvent?(.didPromote(destination: destination))
            guard let identity = Self.fileIdentity(at: destination) else {
                throw ModelManagerError.noDownloadedFile
            }
            let receipt = VerificationReceipt(
                version: VerificationReceipt.currentVersion,
                modelID: id,
                source: Self.resumeSourceIdentity(source),
                pinnedSHA256: pinnedSHA256?.lowercased(),
                expectedSHA256: evidence.expectedSHA256?.lowercased(),
                actualSHA256: evidence.actualSHA256?.lowercased(),
                outcome: evidence.outcome == .unverified ? "unverified" : "sha256",
                fileSize: identity.size,
                modificationNanoseconds: identity.modified
            )
            let data = try JSONEncoder().encode(receipt)
            try data.write(to: Self.verificationReceiptURL(for: destination), options: .atomic)
            return evidence.outcome
        } catch {
            try? FileManager.default.removeItem(at: result.stagingURL)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: Self.verificationReceiptURL(for: destination))
            if let managerError = error as? ModelManagerError { throw managerError }
            throw ModelManagerError.downloadFailed(underlying: error)
        }
    }

    // MARK: - Disk-space preflight

    /// Pure comparison, split out so it's unit-testable without touching the real volume.
    /// Throws `.insufficientDiskSpace` with the human-facing GB figures when the download won't fit.
    static func checkDiskSpace(neededBytes: Int64, availableBytes: Int64) throws {
        guard availableBytes < neededBytes else { return }
        throw ModelManagerError.insufficientDiskSpace(neededGB: Double(neededBytes) / 1e9,
                                                      availableGB: Double(availableBytes) / 1e9)
    }

    /// Queries the models volume's `volumeAvailableCapacityForImportantUsage` and throws when the
    /// expected download size won't fit. An unreadable capacity is treated as "unknown, proceed" —
    /// the download itself will fail with a normal error if the disk really is full.
    private func preflightDiskSpace(neededBytes: Int64, at directory: URL) throws {
        let capacity: Int64?
        if let availableCapacity {
            capacity = availableCapacity(directory)
        } else {
            capacity = (try? directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ))?.volumeAvailableCapacityForImportantUsage
        }
        guard let capacity else { return }
        try Self.checkDiskSpace(neededBytes: neededBytes, availableBytes: capacity)
    }

    // MARK: - Paths

    private func modelsDirectory() -> URL {
        if let modelsDirectoryOverride { return modelsDirectoryOverride }
        let base: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first {
            base = appSupport
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        }
        return base
            .appendingPathComponent("Shadowtype", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    // MARK: - Download

    /// What the server told us about the object it served, captured from the SAME request we already
    /// make: Hugging Face puts the LFS object's real SHA-256 in `X-Linked-Etag` and its byte count in
    /// `X-Linked-Size`. That is what lets us verify EVERY entry instead of only the ones with a
    /// hand-pinned hash.
    private struct DownloadResult {
        let stagingURL: URL
        let linkedSHA256: String?
        let linkedSize: Int64?
    }

    /// Where the resume blob for `destination` lives (`<file>.gguf.resume`), next to the download so a
    /// user who deletes the model also drops its stale resume state.
    static func resumeDataURL(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }

    /// Resume blobs must be keyed by SOURCE as well as destination. `downloadTask(withResumeData:)`
    /// ignores the request it is handed and continues the URL archived inside the blob, while HF
    /// filenames are emphatically not unique across repos (`model.Q4_K_M.gguf` from mradermacher,
    /// bartowski and unsloth all land on the same imported path). Keyed by destination alone, a
    /// cancelled import of repo A leaves a blob that a later import of repo B's identically-named file
    /// picks up — and silently downloads A's bytes under B's name. Folding a digest of the source in
    /// means a blob for a different URL simply isn't found and the download restarts clean, which is
    /// the correct outcome.
    static func resumeDataURL(for destination: URL, source: URL) -> URL {
        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return destination.appendingPathExtension(digest).appendingPathExtension("resume")
    }

    /// Sidecar holding the `X-Linked-*` values captured on the original `resolve` redirect, so a
    /// resumed attempt — which never replays that hop — can still be size- and hash-checked. Kept
    /// beside the resume blob rather than inside it so `isPlausibleResumeData` still validates the
    /// opaque URLSession plist unchanged.
    static func linkedMetadataURL(for resumeURL: URL) -> URL {
        resumeURL.appendingPathExtension("meta")
    }

    struct LinkedMetadata: Codable, Equatable {
        let sha256: String?
        let size: Int64?
        var isEmpty: Bool { sha256 == nil && size == nil }
    }

    static func writeLinkedMetadata(_ meta: LinkedMetadata, besideResumeAt resumeURL: URL) {
        guard !meta.isEmpty, let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: linkedMetadataURL(for: resumeURL), options: .atomic)
    }

    static func readLinkedMetadata(besideResumeAt resumeURL: URL) -> LinkedMetadata? {
        guard let data = try? Data(contentsOf: linkedMetadataURL(for: resumeURL)),
              let meta = try? JSONDecoder().decode(LinkedMetadata.self, from: data),
              !meta.isEmpty else { return nil }
        return meta
    }

    struct AuthenticatedResumeState: Codable, Equatable {
        let sourceIdentity: String
        let offset: Int64
        let sha256: String?
        let size: Int64?
    }

    static func authenticatedResumeStateURL(for destination: URL, source: URL) -> URL {
        let digest = SHA256.hash(data: Data(resumeSourceIdentity(source).utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return destination.appendingPathExtension(digest).appendingPathExtension("range.json")
    }

    static func resumeSourceIdentity(_ source: URL) -> String {
        guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            return source.path
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? source.path
    }

    static func readAuthenticatedResumeState(at url: URL, source: URL,
                                             stagingURL: URL) -> AuthenticatedResumeState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AuthenticatedResumeState.self, from: data),
              state.sourceIdentity == resumeSourceIdentity(source),
              state.offset > 0,
              let size = (try? FileManager.default.attributesOfItem(
                atPath: stagingURL.path
              )[.size] as? NSNumber)?.int64Value,
              size == state.offset else {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: stagingURL)
            return nil
        }
        return state
    }

    /// URLSession's resume blob is an opaque property list. Handing `downloadTask(withResumeData:)`
    /// something that is not that plist has historically raised an ObjC exception (uncatchable from
    /// Swift) instead of failing the task, so we check the shape first and treat anything else as
    /// "no resume data". Pure + testable.
    static func isPlausibleResumeData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return false }
        return dict["NSURLSessionResumeInfoVersion"] != nil || dict["NSURLSessionDownloadURL"] != nil
    }

    /// Read a persisted resume blob, deleting it when it is unusable so a corrupt file can never wedge
    /// the download at "always fails".
    static func readResumeData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard isPlausibleResumeData(data) else {
            try? FileManager.default.removeItem(at: url)
            // The carried X-Linked-* describe the transfer this blob belonged to; a discarded blob
            // means a clean restart, which will see the `resolve` redirect and capture them again.
            try? FileManager.default.removeItem(at: linkedMetadataURL(for: url))
            return nil
        }
        return data
    }

    /// Download `url` to `destination`, RESUMING a previously interrupted transfer when we have a
    /// resume blob for it. A dropped connection at 90% of a 14 GB model used to restart from byte 0
    /// (the async `download(for:)` convenience cannot hand back resume data on failure), which on a
    /// metered or flaky link is the difference between usable and not.
    @discardableResult
    private func download(from url: URL, to destination: URL) async throws -> DownloadResult {
        // Cooperative cancellation: a caller cancelling its Task (e.g. the HF import sheet's Cancel
        // button) must abort the transfer instead of completing + registering the import.
        try Task.checkCancellation()

        let request = URLRequest(url: url)

        let resumeURL = Self.resumeDataURL(for: destination, source: url)
        if let stored = Self.readResumeData(at: resumeURL) {
            // Consume the blob: the delegate writes a FRESH one if this attempt also gets interrupted,
            // so afterwards "a resume file exists" means "this attempt made progress worth keeping".
            try? FileManager.default.removeItem(at: resumeURL)
            do {
                return try await runDownload(request: request, resumeData: stored,
                                             to: destination, resumeURL: resumeURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A resume blob goes stale in ways the API does not distinguish: the tmp file it points
                // at was purged, the object's ETag moved on, the blob was truncated by a crash. Those
                // fail with no new resume data — restart clean rather than wedging the user forever.
                // But when fresh resume data DID land, the transfer really was progressing and merely
                // got interrupted again: keep it and report the failure, because restarting would throw
                // away every byte the user already paid for.
                if FileManager.default.fileExists(atPath: resumeURL.path) { throw error }
                NSLog("[Shadowtype] resume data for \(destination.lastPathComponent) was unusable "
                      + "(\(error.localizedDescription)); restarting the download from the beginning")
                try Task.checkCancellation()
            }
        }
        return try await runDownload(request: request, resumeData: nil,
                                     to: destination, resumeURL: resumeURL)
    }

    /// One transfer attempt. Throws only `ModelManagerError` or `CancellationError`.
    private func runDownload(request: URLRequest, resumeData: Data?,
                             to destination: URL, resumeURL: URL) async throws -> DownloadResult {
        // The download task has to be delegate-held (not `session.download(for:)`) precisely so the
        // failure path can hand back resume data; the delegate persists it next to the partial file.
        let staging = destination.appendingPathExtension("part")
        let delegate = DownloadDelegate(onProgress: onDownloadProgress,
                                        stagingURL: staging, resumeDataURL: resumeURL)
        let session = URLSession(configuration: sessionConfiguration,
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)
        let activeTransfer = Self.activeTransfers.register()
        activeTransfer.installCancellation {
            task.cancel(byProducingResumeData: { data in
                if let data {
                    try? data.write(to: resumeURL, options: .atomic)
                    delegate.persistLinkedMetadata(besideResumeAt: resumeURL)
                }
                activeTransfer.markCancellationPersisted()
            })
        }
        defer { Self.activeTransfers.unregister(activeTransfer) }

        let finished: DownloadDelegate.Finished
        do {
            finished = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DownloadDelegate.Finished, Error>) in
                    delegate.attach(cont)
                    task.resume()
                }
            } onCancel: {
                activeTransfer.cancel()
            }
        } catch let error as ModelManagerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces a cancelled Task as URLError(.cancelled); normalize so callers
            // can distinguish a user cancel from a real failure.
            throw CancellationError()
        } catch {
            throw ModelManagerError.downloadFailed(underlying: error)
        }

        // A resumed transfer answers 206, which is inside the success range.
        if let http = finished.response, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: finished.fileURL)
            throw ModelManagerError.serverError(statusCode: http.statusCode)
        }
        // `X-Linked-Etag`/`X-Linked-Size` ride on Hugging Face's `resolve` 302, and a resumed task
        // continues the CDN URL archived in the blob — so it never sees that hop and reports neither.
        // Without the carried-over copy a resumed download silently degrades to the GGUF-magic check,
        // i.e. the tier's whole integrity story would be absent in exactly the flow resume exists for
        // (the 14 GB transfer that died at 90%), which is also where a short result is most likely.
        let carried = Self.readLinkedMetadata(besideResumeAt: resumeURL)
        // Read the carried metadata BEFORE clearing it: completed means there is no partial left.
        try? FileManager.default.removeItem(at: resumeURL)
        try? FileManager.default.removeItem(at: Self.linkedMetadataURL(for: resumeURL))
        return DownloadResult(stagingURL: finished.fileURL,
                              linkedSHA256: finished.linkedSHA256 ?? carried?.sha256,
                              linkedSize: finished.linkedSize ?? carried?.size)
    }

    // M4 BYOM HF: public surface for an authenticated download. Used by the HF import flow
    // (ModelsPane → HF import sheet). Skips ensureModel's cache reuse path because imported
    // entries don't share the curated catalog's hash-pinning contract — but the server-reported
    // `X-Linked-Etag`/`X-Linked-Size` still verify the bytes, and `lastVerification` reports which.
    @discardableResult
    func downloadAuthenticated(from url: URL, to destination: URL,
                               token: String?, expectedSize: Int64? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let initialToken = token?.isEmpty == false ? token : nil
        let reportedSize = try await authenticatedRemoteSize(
            for: url, token: initialToken, knownSize: expectedSize
        )
        if let reportedSize {
            try preflightDiskSpace(neededBytes: reportedSize,
                                   at: destination.deletingLastPathComponent())
        }
        let result = try await runAuthenticatedDownload(
            from: url, to: destination, initialToken: initialToken,
            knownSize: reportedSize
        )
        lastVerification = try verifyAndPromote(result, to: destination,
                                                id: destination.lastPathComponent,
                                                source: url, pinnedSHA256: nil)
        return destination
    }

    private func authenticatedRemoteSize(for url: URL, token: String?,
                                         knownSize: Int64?) async throws -> Int64? {
        if let knownSize, knownSize > 0 { return knownSize }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(http.statusCode) else {
                throw ModelManagerError.serverError(statusCode: http.statusCode)
            }
            return Self.parseLinkedSize(http.value(forHTTPHeaderField: "X-Linked-Size"))
                ?? Self.parseLinkedSize(http.value(forHTTPHeaderField: "Content-Length"))
        } catch let error as ModelManagerError {
            throw error
        } catch {
            throw ModelManagerError.downloadFailed(underlying: error)
        }
    }

    private func runAuthenticatedDownload(from url: URL, to destination: URL,
                                          initialToken: String?,
                                          knownSize: Int64?) async throws -> DownloadResult {
        try Task.checkCancellation()
        let staging = destination.appendingPathExtension("part")
        let stateURL = Self.authenticatedResumeStateURL(for: destination, source: url)
        let resumed = Self.readAuthenticatedResumeState(at: stateURL, source: url,
                                                        stagingURL: staging)
        let offset = resumed?.offset ?? 0
        let currentToken = offset > 0 ? huggingFaceToken() : initialToken
        var request = URLRequest(url: url)
        if let currentToken, !currentToken.isEmpty {
            request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        }
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let delegate = AuthenticatedDownloadDelegate(
            onProgress: onDownloadProgress,
            stagingURL: staging,
            stateURL: stateURL,
            sourceIdentity: Self.resumeSourceIdentity(url),
            initialOffset: offset,
            initialSHA256: resumed?.sha256,
            knownSize: resumed?.size ?? knownSize
        )
        let session = URLSession(configuration: sessionConfiguration,
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        let activeTransfer = Self.activeTransfers.register()
        activeTransfer.installCancellation {
            task.cancel()
            delegate.persistResumeState()
            activeTransfer.markCancellationPersisted()
        }
        defer { Self.activeTransfers.unregister(activeTransfer) }

        let finished: AuthenticatedDownloadDelegate.Finished
        do {
            finished = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<AuthenticatedDownloadDelegate.Finished, Error>) in
                    delegate.attach(continuation)
                    task.resume()
                }
            } onCancel: {
                activeTransfer.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ModelManagerError {
            throw error
        } catch {
            throw ModelManagerError.downloadFailed(underlying: error)
        }
        guard (200...299).contains(finished.statusCode) else {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: stateURL)
            throw ModelManagerError.serverError(statusCode: finished.statusCode)
        }
        return DownloadResult(stagingURL: staging,
                              linkedSHA256: finished.linkedSHA256,
                              linkedSize: finished.linkedSize ?? knownSize)
    }

    // MARK: - Hashing

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MiB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns one transfer: progress, the `X-Linked-*` headers, staging the finished file, and persisting
/// resume data when the transfer dies. State is touched from the URLSession delegate queue and read
/// from the awaiting task, so every field is behind `lock`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    struct Finished {
        let fileURL: URL
        let response: HTTPURLResponse?
        let linkedSHA256: String?
        let linkedSize: Int64?
    }

    private let onProgress: ((Double?) -> Void)?
    private let stagingURL: URL
    private let resumeDataURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Finished, Error>?
    private var linkedSHA256: String?
    private var linkedSize: Int64?
    private var stagedURL: URL?
    private var stageError: Error?
    private var expectedTotalOnResume: Int64 = 0

    init(onProgress: ((Double?) -> Void)?, stagingURL: URL, resumeDataURL: URL) {
        self.onProgress = onProgress
        self.stagingURL = stagingURL
        self.resumeDataURL = resumeDataURL
    }

    /// Attached before `task.resume()`, so no completion can arrive before there is somewhere to send it.
    func attach(_ continuation: CheckedContinuation<Finished, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    /// Persist whatever `X-Linked-*` this attempt saw, so the NEXT (resumed) attempt can still verify.
    /// Called from the cancel handler, where the resume blob is being written.
    func persistLinkedMetadata(besideResumeAt resumeURL: URL) {
        lock.lock(); let sha = linkedSHA256; let size = linkedSize; lock.unlock()
        ModelManager.writeLinkedMetadata(.init(sha256: sha, size: size), besideResumeAt: resumeURL)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let onProgress else { return }
        // A resumed transfer answers 206, whose Content-Length is only the REMAINING range, so
        // totalBytesExpectedToWrite can be unknown here; didResumeAtOffset gives the real total.
        lock.lock(); let resumedTotal = expectedTotalOnResume; lock.unlock()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : resumedTotal
        if total > 0 {
            onProgress(Double(totalBytesWritten) / Double(total))
        } else {
            onProgress(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.lock(); expectedTotalOnResume = expectedTotalBytes; lock.unlock()
    }

    // Hugging Face's `resolve` endpoint answers with a 302 to the CDN and carries the LFS object's
    // SHA-256/size on THAT response, not on the CDN's final 200 — so capture headers on every hop and
    // keep the first values we see.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        capture(headersFrom: response)
        completionHandler(request)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        capture(headersFrom: downloadTask.response as? HTTPURLResponse)
        // URLSession deletes `location` the moment this returns, so the move MUST happen here,
        // synchronously — the awaiting caller can never be handed the temp URL.
        do {
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            lock.lock(); stagedURL = stagingURL; lock.unlock()
        } catch {
            lock.lock(); stageError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        capture(headersFrom: task.response as? HTTPURLResponse)
        if let error {
            // The whole point of the delegate-held task: on failure URLSession hands back a blob that
            // lets the next attempt continue instead of re-pulling gigabytes.
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeDataURL, options: .atomic)
                // Carry the redirect-only X-Linked-* forward: the resumed attempt continues the CDN URL
                // archived in the blob and never replays the `resolve` hop that carries them.
                persistLinkedMetadata(besideResumeAt: resumeDataURL)
            }
            finish(.failure(error))
            return
        }
        lock.lock()
        let staged = stagedURL
        let stageErr = stageError
        let sha = linkedSHA256
        let size = linkedSize
        lock.unlock()
        if let stageErr { finish(.failure(stageErr)); return }
        guard let staged else { finish(.failure(ModelManagerError.noDownloadedFile)); return }
        finish(.success(Finished(fileURL: staged,
                                 response: task.response as? HTTPURLResponse,
                                 linkedSHA256: sha,
                                 linkedSize: size)))
    }

    private func capture(headersFrom response: HTTPURLResponse?) {
        guard let response else { return }
        lock.lock(); defer { lock.unlock() }
        if linkedSHA256 == nil {
            linkedSHA256 = ModelManager.parseLinkedSHA256(response.value(forHTTPHeaderField: "X-Linked-Etag"))
        }
        if linkedSize == nil {
            linkedSize = ModelManager.parseLinkedSize(response.value(forHTTPHeaderField: "X-Linked-Size"))
        }
    }

    private func finish(_ result: Result<Finished, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil          // a continuation must be resumed exactly once
        lock.unlock()
        cont?.resume(with: result)
    }
}

/// Streams authenticated responses into an app-owned partial file. The persisted state contains only
/// an offset and integrity metadata; Authorization is rebuilt from Keychain for every resumed request.
private final class AuthenticatedDownloadDelegate: NSObject, URLSessionDataDelegate {
    struct Finished {
        let statusCode: Int
        let linkedSHA256: String?
        let linkedSize: Int64?
    }

    private let onProgress: ((Double?) -> Void)?
    private let stagingURL: URL
    private let stateURL: URL
    private let sourceIdentity: String
    private let initialOffset: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Finished, Error>?
    private var handle: FileHandle?
    private var receivedOffset: Int64
    private var linkedSHA256: String?
    private var linkedSize: Int64?
    private var statusCode = 0
    private var streamError: Error?

    init(onProgress: ((Double?) -> Void)?, stagingURL: URL, stateURL: URL,
         sourceIdentity: String, initialOffset: Int64, initialSHA256: String?,
         knownSize: Int64?) {
        self.onProgress = onProgress
        self.stagingURL = stagingURL
        self.stateURL = stateURL
        self.sourceIdentity = sourceIdentity
        self.initialOffset = initialOffset
        self.receivedOffset = initialOffset
        self.linkedSHA256 = initialSHA256
        self.linkedSize = knownSize
    }

    func attach(_ continuation: CheckedContinuation<Finished, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func persistResumeState() {
        lock.lock()
        try? handle?.synchronize()
        let offset = receivedOffset
        let sha = linkedSHA256
        let size = linkedSize
        lock.unlock()
        guard offset > 0,
              let data = try? JSONEncoder().encode(ModelManager.AuthenticatedResumeState(
                sourceIdentity: sourceIdentity, offset: offset, sha256: sha, size: size
              )) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        capture(headersFrom: response)
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(ModelManagerError.downloadFailed(
                underlying: URLError(.badServerResponse)
            )))
            return
        }
        capture(headersFrom: http)
        statusCode = http.statusCode
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.allow)
            return
        }
        do {
            var append = initialOffset > 0
            if initialOffset > 0, http.statusCode == 206 {
                guard Self.contentRangeStart(http.value(forHTTPHeaderField: "Content-Range"))
                        == initialOffset else {
                    throw URLError(.badServerResponse)
                }
            } else if initialOffset > 0 {
                append = false
                receivedOffset = 0
            }
            if !append {
                try? FileManager.default.removeItem(at: stagingURL)
                FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
            }
            let file = try FileHandle(forWritingTo: stagingURL)
            if append {
                try file.seekToEnd()
            } else {
                try file.truncate(atOffset: 0)
            }
            lock.lock(); handle = file; lock.unlock()
            completionHandler(.allow)
        } catch {
            lock.lock(); streamError = error; lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        do {
            try handle?.write(contentsOf: data)
            receivedOffset += Int64(data.count)
            let offset = receivedOffset
            let total = linkedSize
            lock.unlock()
            if let total, total > 0 {
                onProgress?(min(1, Double(offset) / Double(total)))
            } else {
                onProgress?(nil)
            }
        } catch {
            streamError = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        capture(headersFrom: task.response as? HTTPURLResponse)
        lock.lock()
        try? handle?.close()
        handle = nil
        let streamError = streamError
        let finished = Finished(statusCode: statusCode,
                                linkedSHA256: linkedSHA256,
                                linkedSize: linkedSize)
        lock.unlock()
        if let error = streamError ?? error {
            persistResumeState()
            finish(.failure(error))
        } else {
            try? FileManager.default.removeItem(at: stateURL)
            finish(.success(finished))
        }
    }

    private func capture(headersFrom response: HTTPURLResponse?) {
        guard let response else { return }
        lock.lock(); defer { lock.unlock() }
        if linkedSHA256 == nil {
            linkedSHA256 = ModelManager.parseLinkedSHA256(
                response.value(forHTTPHeaderField: "X-Linked-Etag")
            )
        }
        if linkedSize == nil {
            linkedSize = ModelManager.parseLinkedSize(
                response.value(forHTTPHeaderField: "X-Linked-Size")
            )
            if linkedSize == nil {
                linkedSize = ModelManager.parseLinkedSize(
                    response.value(forHTTPHeaderField: "Content-Length")
                ).map { initialOffset + $0 }
            }
        }
    }

    private func finish(_ result: Result<Finished, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func contentRangeStart(_ value: String?) -> Int64? {
        guard let value, value.lowercased().hasPrefix("bytes "),
              let range = value.dropFirst(6).split(separator: "/").first,
              let start = range.split(separator: "-").first else { return nil }
        return Int64(start)
    }
}

private final class ActiveTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let persisted = DispatchSemaphore(value: 0)
    private var cancellation: (() -> Void)?
    private var cancelled = false
    private var didPersist = false

    func installCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        self.cancellation = cancellation
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { cancellation() }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let cancellation = cancellation
        lock.unlock()
        cancellation?()
    }

    func markCancellationPersisted() {
        lock.lock()
        guard !didPersist else { lock.unlock(); return }
        didPersist = true
        lock.unlock()
        persisted.signal()
    }

    func waitForCancellationPersistence(until deadline: DispatchTime) -> Bool {
        lock.lock()
        let alreadyPersisted = didPersist
        lock.unlock()
        return alreadyPersisted || persisted.wait(timeout: deadline) == .success
    }
}

private final class ActiveTransferRegistry {
    private let lock = NSLock()
    private var transfers: [ObjectIdentifier: ActiveTransfer] = [:]

    func register() -> ActiveTransfer {
        let transfer = ActiveTransfer()
        lock.lock(); transfers[ObjectIdentifier(transfer)] = transfer; lock.unlock()
        return transfer
    }

    func unregister(_ transfer: ActiveTransfer) {
        lock.lock(); transfers.removeValue(forKey: ObjectIdentifier(transfer)); lock.unlock()
    }

    func cancelAllAndWait(timeout: TimeInterval) -> Bool {
        lock.lock(); let active = Array(transfers.values); lock.unlock()
        active.forEach { $0.cancel() }
        let deadline = DispatchTime.now() + timeout
        return active.allSatisfy { $0.waitForCancellationPersistence(until: deadline) }
    }
}
