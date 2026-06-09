// Diag — temporary field-debugging logger (M2). Unified-logging retention for NSLog is flaky, so
// we also append to a plain file we can read back directly: ~/Library/Application Support/Shadowtype/diag.log
// Remove once the live capture/overlay path is verified on real apps.
import Foundation
import os

enum Diag {
    private static let logger = Logger(subsystem: "com.shadowtype.app", category: "diag")
    private static let queue = DispatchQueue(label: "com.shadowtype.diag")

    // Opt-in only: avoids a file write on every keystroke during normal use.
    // Enabled when env SHADOWTYPE_DIAG=1, or UserDefaults bool "ShadowtypeDiag" is true.
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["SHADOWTYPE_DIAG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "ShadowtypeDiag")
    }()

    // Raw typed content (keystroke characters, prefix/completion text) goes through logContent() and
    // is gated behind this SEPARATE, more explicit opt-in, so ordinary diag (decision paths, keycodes,
    // lengths, caret geometry) never writes the user's text — or a password — to disk. Enable only
    // when actively debugging a content issue.
    static let isContentEnabled: Bool = {
        if ProcessInfo.processInfo.environment["SHADOWTYPE_DIAG_CONTENT"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "ShadowtypeDiagContent")
    }()

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Shadowtype", isDirectory: true)
            .appendingPathComponent("diag.log", isDirectory: false)
    }()

    // Truncate at launch so each run starts clean.
    static func reset() {
        guard isEnabled else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Owner-only (0600): the log may hold typed content when content-diag is on — never let it be
        // group/world-readable. createFile truncates + applies the perms in one step.
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
        log("=== diag start ===")
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        let safe = redactSecrets(message)
        logger.log("\(safe, privacy: .public)")
        queue.async {
            let line = "\(timestamp()) \(safe)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    // Like log(), but for raw typed content — only emits when content-diag is ALSO enabled.
    static func logContent(_ message: String) {
        guard isContentEnabled else { return }
        log(message)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    // M4 BYOM HF: scrub common secret-shaped patterns before anything hits os.Logger or the
    // plaintext diag file. This is defense-in-depth — the M4 code paths deliberately never log
    // HF tokens or Authorization headers — but a future contributor could accidentally pass
    // either through Diag.log, and this strips it before disk hit.
    //
    // We don't try to catch every secret format on earth (a generic regex match for "long hex
    // string" would mangle legitimate logs like model IDs); we hit the three concrete shapes we
    // know our app handles: HF Bearer tokens, Authorization header values, and `?token=...`
    // URL query params.
    static func redactSecrets(_ s: String) -> String {
        var out = s
        // Authorization header value (most likely to appear if URLRequest is ever printed).
        if let r = out.range(of: #"(?i)Authorization:\s*Bearer\s+[A-Za-z0-9._\-]+"#, options: .regularExpression) {
            out.replaceSubrange(r, with: "Authorization: Bearer <redacted>")
        }
        // HuggingFace user-access-tokens start with `hf_`.
        if let _ = out.range(of: #"hf_[A-Za-z0-9]{8,}"#, options: .regularExpression) {
            out = out.replacingOccurrences(
                of: #"hf_[A-Za-z0-9]{8,}"#,
                with: "hf_<redacted>",
                options: .regularExpression)
        }
        // `?token=...` style query params (covers HF + generic).
        out = out.replacingOccurrences(
            of: #"([?&])token=[^&\s"']+"#,
            with: "$1token=<redacted>",
            options: .regularExpression)
        return out
    }
}
