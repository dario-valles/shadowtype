// HFResolver — M4 BYOM: HuggingFace URL parsing + repo file listing for the "Import from
// HuggingFace…" import flow. Two URL shapes the UI accepts:
//
//   1. Direct file URL — `https://huggingface.co/{owner}/{repo}/resolve/<rev>/<file>.gguf`
//      Already names the .gguf to download. We hand it straight to ModelManager.download (with
//      optional Bearer for gated repos) and skip the API call.
//
//   2. Repo URL — `https://huggingface.co/{owner}/{repo}` (or `tree/<rev>` variants)
//      No specific file named. We GET `https://huggingface.co/api/models/{owner}/{repo}` to
//      enumerate `.gguf` siblings and surface them to the user for a pick. The repo API needs
//      the same Bearer for private/gated repos.
//
// Authorization: when a HF token is configured in APIKeyStore, every request includes
// `Authorization: Bearer <token>`. The token never leaves Keychain except as that header.
import Foundation

enum HFResolver {
    enum Parsed: Equatable {
        case directFile(owner: String, repo: String, revision: String, filename: String, downloadURL: URL)
        case repoOnly(owner: String, repo: String)
        case invalid(reason: String)
    }

    enum Failure: Error {
        case http(Int)
        case malformed(String)
        case noGGUFFiles
        /// Every GGUF in the repo is one part of a split model. Its own case rather than `.malformed`
        /// because the sheet prefixes that one with "Could not contact HuggingFace" — which is false
        /// here: the repo resolved fine, we just refuse what it ships. Payload is the explanation.
        case sharded(String)
    }

    struct Sibling: Equatable {
        let filename: String         // e.g. "Qwen3-1.7B-Base.Q4_K_M.gguf"
        let sizeBytes: Int64?        // best-effort; HF API returns size for LFS files
        let downloadURL: URL         // https://.../resolve/main/{filename}
    }

    // Parse a user-pasted URL string into a discriminated case. Whitespace-trimmed; trailing
    // slashes ignored.
    static func parse(_ raw: String) -> Parsed {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s),
              url.scheme?.lowercased() == "https",
              let host = url.host, host == "huggingface.co" else {
            return .invalid(reason: "URL must use HTTPS and point at huggingface.co")
        }
        // Path components: ["/", owner, repo, ...maybeMore]
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return .invalid(reason: "URL must include {owner}/{repo}") }
        let owner = parts[0]
        let repo = parts[1]

        // Direct: .../resolve/<rev>/<...path>/<file>.gguf
        if parts.count >= 5, parts[2] == "resolve" {
            let revision = parts[3]
            // Everything after revision is the file path inside the repo. The HF resolve URL is
            // already canonical; we use it as-is.
            let filename = parts.suffix(from: 4).joined(separator: "/")
            guard filename.hasSuffix(".gguf") else {
                return .invalid(reason: "direct URL must point at a .gguf file (got \(filename))")
            }
            let base = (filename as NSString).lastPathComponent
            // A shard carries the GGUF magic, so downloading one "succeeds" and then dies at load with
            // the generic "may be corrupt or unsupported". Say why instead.
            if let shard = shardInfo(base) {
                return .invalid(reason: "\(base) is part \(shard.index) of \(shard.total) of a split "
                                + "model. A single shard cannot be loaded on its own — pick a file that "
                                + "ships the whole model as one .gguf.")
            }
            return .directFile(owner: owner, repo: repo, revision: revision,
                               filename: base,
                               downloadURL: url)
        }

        // Repo-only or repo with tree/blob — we treat any non-resolve URL as repo-only and let
        // the API listing surface the actual files.
        return .repoOnly(owner: owner, repo: repo)
    }

    // GET https://huggingface.co/api/models/{owner}/{repo} → parse siblings array, filter to
    // importable .gguf files (single-file only — see `shardInfo`), build canonical download URLs.
    // The HF API returns:
    //   { "siblings": [ {"rfilename": "...", "size": <bytes-optional>}, ... ] }
    static func listGGUFs(owner: String, repo: String, token: String? = nil,
                          session: URLSession = .shared,
                          completion: @escaping (Result<[Sibling], Failure>) -> Void) {
        guard let url = URL(string: "https://huggingface.co/api/models/\(owner)/\(repo)") else {
            completion(.failure(.malformed("could not build API URL"))); return
        }
        var req = URLRequest(url: url)
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: req) { data, resp, err in
            if let err {
                completion(.failure(.malformed("network: \(err.localizedDescription)"))); return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status >= 300 {
                completion(.failure(.http(status))); return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.malformed("non-JSON response"))); return
            }
            let siblingsRaw = (obj["siblings"] as? [[String: Any]]) ?? []
            let ggufs: [Sibling] = siblingsRaw.compactMap { s in
                guard let name = s["rfilename"] as? String, name.hasSuffix(".gguf") else { return nil }
                let size = (s["size"] as? Int64) ?? (s["size"] as? NSNumber)?.int64Value
                // rfilename can carry spaces or a subdir path → URL(string:) returns nil; percent-encode
                // and SKIP an unbuildable sibling rather than trapping (was a force-unwrap that crashed).
                guard let dl = Self.siblingDownloadURL(owner: owner, repo: repo, name: name) else { return nil }
                return Sibling(filename: name, sizeBytes: size, downloadURL: dl)
            }
            // Split repos (essentially every 70B-class repo, i.e. exactly what BYOM exists for) must
            // never reach the picker: importing one shard registers a model that cannot load.
            let split = Self.partitionShards(ggufs)
            if split.whole.isEmpty {
                if split.shards.isEmpty { completion(.failure(.noGGUFFiles)) }
                else { completion(.failure(.sharded(Self.shardRejectionMessage(split.shards)))) }
                return
            }
            completion(.success(split.whole))
        }
        task.resume()
    }

    // Build the canonical resolve URL for a repo sibling. `name` (HF rfilename) may contain spaces or a
    // subdir path, so percent-encode it (the URL-path set keeps "/"). Returns nil when the name still
    // can't form a valid URL — the caller skips that sibling instead of crashing. Pure + testable.
    static func siblingDownloadURL(owner: String, repo: String, name: String) -> URL? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://huggingface.co/\(owner)/\(repo)/resolve/main/\(encoded)")
    }

    // Picker ordering: ascending by size so the cheapest download reads first; unknown sizes sink
    // to the bottom; filename breaks ties for a stable order. Pure + testable.
    static func sortedBySizeAscending(_ list: [Sibling]) -> [Sibling] {
        list.sorted { a, b in
            switch (a.sizeBytes, b.sizeBytes) {
            case let (x?, y?): return x != y ? x < y : a.filename < b.filename
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.filename < b.filename
            }
        }
    }

    // Default pick for the import picker: a Q4_K_M quant when the repo has one (the recommended
    // quality/size balance, matching the curated catalog), preferring an imatrix build of that same
    // quant — same file size and speed, measurably lower perplexity on rare tokens and non-English
    // text — else the first file. Shards are never pre-selected: they cannot load alone. Pure + testable.
    static func preferredImportFile(in list: [Sibling]) -> Sibling? {
        let usable = list.filter { shardInfo($0.filename) == nil }
        let q4 = usable.filter { $0.filename.lowercased().contains("q4_k_m") }
        return q4.first(where: { isIMatrixBuild($0.filename) }) ?? q4.first ?? usable.first
    }

    // MARK: - Sharded (split) GGUFs

    // A split model is published as `<name>-00001-of-00003.gguf`: llama.cpp needs EVERY shard present
    // in one directory to load it, but the import flow downloads exactly one file. Since each shard
    // still starts with the GGUF magic, accepting one passes validation, registers the model, and then
    // fails at load with the generic "may be corrupt or unsupported" — so detect the pattern and say
    // what is actually wrong. `-00001-of-00001` is a complete model despite the suffix, so it is NOT a
    // shard. Pure + testable.
    static func shardInfo(_ filename: String) -> (index: Int, total: Int)? {
        let base = (filename as NSString).lastPathComponent.lowercased()
        guard base.hasSuffix(".gguf") else { return nil }
        let parts = String(base.dropLast(".gguf".count)).split(separator: "-",
                                                               omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[parts.count - 2] == "of" else { return nil }
        let idxPart = parts[parts.count - 3], totalPart = parts[parts.count - 1]
        func isFiveDigits(_ s: Substring) -> Bool {
            s.count == 5 && s.allSatisfy { c in c.isASCII && c.isNumber }
        }
        guard isFiveDigits(idxPart), isFiveDigits(totalPart),
              let index = Int(idxPart), let total = Int(totalPart),
              total >= 2, index >= 1, index <= total else { return nil }
        return (index, total)
    }

    // Separate importable single-file GGUFs from the shards we refuse. Pure so the sharded-repo case
    // is testable without a network call.
    static func partitionShards(_ list: [Sibling]) -> (whole: [Sibling], shards: [Sibling]) {
        var whole: [Sibling] = [], shards: [Sibling] = []
        for s in list {
            if shardInfo(s.filename) == nil { whole.append(s) } else { shards.append(s) }
        }
        return (whole, shards)
    }

    // User-facing explanation for a repo whose GGUFs are ALL shards. Names a concrete file so the user
    // can see the `-00001-of-000NN` pattern we rejected rather than guessing.
    static func shardRejectionMessage(_ shards: [Sibling]) -> String {
        let example = shards.first?.filename ?? "…-00001-of-00002.gguf"
        return "every GGUF in this repo is one part of a split model (e.g. \(example)). Shadowtype "
            + "imports a single file, and one shard cannot be loaded on its own — pick a repo that "
            + "ships the model as a single .gguf."
    }

    // mradermacher publishes imatrix quants as `…i1-Q4_K_M.gguf` (from its `-i1-GGUF` repos); other
    // uploaders mark them `imat`/`imatrix`. Matched as a whole token so a model name that merely
    // contains those letters can't be mistaken for one. Pure + testable.
    static func isIMatrixBuild(_ filename: String) -> Bool {
        let tokens = filename.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains { $0 == "i1" || $0 == "imat" || $0 == "imatrix" }
    }

    // Best-effort short label for a sibling row in the picker UI.
    static func displaySize(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "" }
        let gb = Double(b) / (1024 * 1024 * 1024)
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
