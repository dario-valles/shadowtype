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
        }
    }
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
    /// code as the default model. Returns early if the file is already present. When `entry.sha256` is
    /// non-nil, verifies exactly like the default path (remove + throw `checksumMismatch` on mismatch);
    /// when it is nil, SKIPS verification but logs a clear warning (PRD §6 honesty about checksums — the
    /// paid entries ship with `sha256 == nil` until their real hashes are pinned at release).
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
            return target
        }
        let destination = modelURL(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            // A hash-pinned entry was verified before it was trusted; reuse it (re-hashing a multi-GB file
            // every launch is too costly). A nil-hash entry has NO such guarantee, so a cheap GGUF-magic
            // sanity check guards against a truncated/corrupt prior download being reused forever.
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
        try await download(from: entry.url, to: destination)

        if let expected = entry.sha256 {
            guard verifySHA256(destination, expected: expected) else {
                let actual = (try? sha256Hex(of: destination)) ?? "<unreadable>"
                try? FileManager.default.removeItem(at: destination)
                throw ModelManagerError.checksumMismatch(expected: expected, actual: actual)
            }
        } else {
            // No pinned hash (PRD §6 honesty): we can't verify the exact bytes, but we MUST reject a
            // truncated download / HTML error page / non-model file before it reaches engine.load — so
            // validate the GGUF magic header at minimum, and delete + throw on failure.
            guard Self.isValidGGUF(destination) else {
                try? FileManager.default.removeItem(at: destination)
                throw ModelManagerError.invalidModelFile(entry.id)
            }
            NSLog("[Shadowtype] WARNING: no pinned SHA-256 for model \(entry.id); verified GGUF magic only")
        }
        return destination
    }

    // Cheap integrity gate for nil-hash models: a real GGUF begins with the 4-byte ASCII magic "GGUF".
    // Reading 4 bytes is O(1) regardless of the multi-GB file size, so it's safe on the cached-reuse path.
    static func isValidGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        return magic == Data([0x47, 0x47, 0x55, 0x46])   // "GGUF"
    }

    func verifySHA256(_ url: URL, expected: String) -> Bool {
        guard let actual = try? sha256Hex(of: url) else { return false }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
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

    private func download(from url: URL, to destination: URL,
                          authorization: String? = nil) async throws {
        // Cooperative cancellation: a caller cancelling its Task (e.g. the HF import sheet's Cancel
        // button) must abort the transfer instead of completing + registering the import.
        try Task.checkCancellation()
        let delegate = DownloadDelegate(onProgress: onDownloadProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // M4 BYOM: optional Authorization header for HuggingFace gated/private repos. The token
        // is sourced from Keychain (APIKeyStore.huggingfaceToken), never UserDefaults / disk.
        // Diag.swift is audited to never log this header value.
        var request = URLRequest(url: url)
        if let auth = authorization, !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        do {
            let (tempURL, response) = try await session.download(for: request, delegate: delegate)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ModelManagerError.serverError(statusCode: http.statusCode)
            }
            // Move into place atomically; replace any partial leftover.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch let error as ModelManagerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces a cancelled Task as URLError(.cancelled); normalize so callers
            // can distinguish a user cancel from a real failure.
            throw CancellationError()
        } catch {
            // URLSession download resumes automatically from partial data on transient failures;
            // a thrown error here means the download could not complete.
            throw ModelManagerError.downloadFailed(underlying: error)
        }
    }

    // M4 BYOM HF: public surface for an authenticated download. Used by the HF import flow
    // (ModelsPane → HF import sheet). Skips ensureModel's cache reuse path because imported
    // entries don't share the curated catalog's hash-pinning contract.
    @discardableResult
    func downloadAuthenticated(from url: URL, to destination: URL,
                               token: String?) async throws -> URL {
        let auth = (token?.isEmpty == false) ? "Bearer \(token!)" : nil
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await download(from: url, to: destination, authorization: auth)
        guard Self.isValidGGUF(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ModelManagerError.invalidModelFile(destination.lastPathComponent)
        }
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

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: ((Double?) -> Void)?

    init(onProgress: ((Double?) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let onProgress else { return }
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            onProgress(nil)
        }
    }

    // Required by the protocol; the async `download(from:)` API consumes the file itself,
    // so no work is needed here.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
