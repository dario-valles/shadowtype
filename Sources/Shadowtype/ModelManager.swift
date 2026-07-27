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
            return URL(fileURLWithPath: imported.linkedPath)
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
            lastVerification = nil
            return target
        }
        let destination = modelURL(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            lastVerification = nil   // nothing was downloaded: don't report a stale verdict
            // A hash-pinned entry was verified before it was trusted; reuse it (re-hashing a multi-GB file
            // every launch is too costly). For a nil-hash entry we cannot tell after the fact whether the
            // download was header-verified — no verdict is persisted — so a cheap GGUF-magic sanity check
            // still guards against a truncated/corrupt prior download being reused forever.
            if entry.sha256 != nil || Self.isValidGGUF(destination) { return destination }
            NSLog("[Shadowtype] WARNING: cached model \(entry.id) failed GGUF sanity check; re-downloading")
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: modelsDirectory(),
                                                withIntermediateDirectories: true)
        // Disk-space preflight: fail fast with an actionable message instead of letting a multi-GB
        // download die mid-flight (or fill the volume). Surfaces through the same error path as any
        // other download failure (.shadowtypeModelDidChange userInfo["error"]).
        try preflightDiskSpace(neededBytes: Int64(entry.downloadGB * 1e9))
        let result = try await download(from: entry.url, to: destination)
        lastVerification = try verifyDownloaded(destination, id: entry.id,
                                                pinnedSHA256: entry.sha256, result: result)
        return destination
    }

    /// Check the freshly-written bytes and report what actually vouched for them. Deletes the file and
    /// throws on ANY mismatch — a bad multi-GB file must never reach engine.load, nor be reused as a
    /// cached download forever. Ordered cheapest-first: 4-byte magic, then the byte count, then the
    /// full hash (which re-reads the file in 1 MiB chunks — never all at once).
    private func verifyDownloaded(_ destination: URL, id: String,
                                  pinnedSHA256: String?, result: DownloadResult) throws -> ModelVerification {
        // An HTML error page or an aborted transfer that still produced a file: reject before spending
        // a full-file read on hashing it.
        guard Self.isValidGGUF(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ModelManagerError.invalidModelFile(id)
        }
        // Truncation is the common real-world failure and it sails past the magic check, so compare the
        // byte count against `X-Linked-Size` whenever the server gave us one.
        if let expectedSize = result.linkedSize {
            let actualSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                              as? NSNumber)?.int64Value ?? -1
            do {
                try Self.checkDownloadedSize(expected: expectedSize, actual: actualSize)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        let plan = Self.verificationPlan(pinnedSHA256: pinnedSHA256, linkedSHA256: result.linkedSHA256)
        if let expected = plan.expected {
            let actual = (try? sha256Hex(of: destination)) ?? "<unreadable>"
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: destination)
                throw ModelManagerError.checksumMismatch(expected: expected, actual: actual)
            }
        } else {
            NSLog("[Shadowtype] WARNING: \(id) has no pinned SHA-256 and the server sent no usable "
                  + "X-Linked-Etag; verified GGUF magic only — NOT hash-verified")
        }
        return plan.outcome
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
    private func preflightDiskSpace(neededBytes: Int64) throws {
        let dir = modelsDirectory()
        guard let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = vals.volumeAvailableCapacityForImportantUsage else { return }
        try Self.checkDiskSpace(neededBytes: neededBytes, availableBytes: available)
    }

    // MARK: - Paths

    private func modelsDirectory() -> URL {
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
    private func download(from url: URL, to destination: URL,
                          authorization: String? = nil) async throws -> DownloadResult {
        // Cooperative cancellation: a caller cancelling its Task (e.g. the HF import sheet's Cancel
        // button) must abort the transfer instead of completing + registering the import.
        try Task.checkCancellation()

        // M4 BYOM: optional Authorization header for HuggingFace gated/private repos. The token
        // is sourced from Keychain (APIKeyStore.huggingfaceToken), never UserDefaults / disk.
        // Diag.swift is audited to never log this header value.
        var request = URLRequest(url: url)
        if let auth = authorization, !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

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
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)

        let finished: DownloadDelegate.Finished
        do {
            finished = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DownloadDelegate.Finished, Error>) in
                    delegate.attach(cont)
                    task.resume()
                }
            } onCancel: {
                // Cancel WITH resume data so the import sheet's Cancel (or an app quit) doesn't throw
                // away a multi-GB partial transfer the user may well want to finish later.
                task.cancel(byProducingResumeData: { data in
                    if let data {
                        try? data.write(to: resumeURL, options: .atomic)
                        delegate.persistLinkedMetadata(besideResumeAt: resumeURL)
                    }
                })
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
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: finished.fileURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: finished.fileURL)
            throw ModelManagerError.downloadFailed(underlying: error)
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
        return DownloadResult(linkedSHA256: finished.linkedSHA256 ?? carried?.sha256,
                              linkedSize: finished.linkedSize ?? carried?.size)
    }

    // M4 BYOM HF: public surface for an authenticated download. Used by the HF import flow
    // (ModelsPane → HF import sheet). Skips ensureModel's cache reuse path because imported
    // entries don't share the curated catalog's hash-pinning contract — but the server-reported
    // `X-Linked-Etag`/`X-Linked-Size` still verify the bytes, and `lastVerification` reports which.
    @discardableResult
    func downloadAuthenticated(from url: URL, to destination: URL,
                               token: String?) async throws -> URL {
        let auth = (token?.isEmpty == false) ? "Bearer \(token!)" : nil
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let result = try await download(from: url, to: destination, authorization: auth)
        lastVerification = try verifyDownloaded(destination, id: destination.lastPathComponent,
                                                pinnedSHA256: nil, result: result)
        return destination
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
