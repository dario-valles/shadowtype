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
              let host = url.host, host == "huggingface.co" else {
            return .invalid(reason: "URL must point at huggingface.co")
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
            return .directFile(owner: owner, repo: repo, revision: revision,
                               filename: (filename as NSString).lastPathComponent,
                               downloadURL: url)
        }

        // Repo-only or repo with tree/blob — we treat any non-resolve URL as repo-only and let
        // the API listing surface the actual files.
        return .repoOnly(owner: owner, repo: repo)
    }

    // GET https://huggingface.co/api/models/{owner}/{repo} → parse siblings array, filter to
    // .gguf files, build canonical download URLs. The HF API returns:
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
            if ggufs.isEmpty { completion(.failure(.noGGUFFiles)); return }
            completion(.success(ggufs))
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

    // Best-effort short label for a sibling row in the picker UI.
    static func displaySize(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "" }
        let gb = Double(b) / (1024 * 1024 * 1024)
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
