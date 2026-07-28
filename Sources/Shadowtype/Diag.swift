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
    // This is computed rather than cached so turning diagnostics off clears its retained file promptly.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["SHADOWTYPE_DIAG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "ShadowtypeDiag")
    }

    // Raw typed content (keystroke characters, prefix/completion text) goes through logContent() and
    // is gated behind this SEPARATE, more explicit opt-in, so ordinary diag (decision paths, keycodes,
    // lengths, caret geometry) never writes the user's text — or a password — to disk. Enable only
    // when actively debugging a content issue.
    static var isContentEnabled: Bool {
        guard isEnabled else { return false }
        if ProcessInfo.processInfo.environment["SHADOWTYPE_DIAG_CONTENT"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "ShadowtypeDiagContent")
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Shadowtype", isDirectory: true)
            .appendingPathComponent("diag.log", isDirectory: false)
    }()

    // Retention policy: diagnostics are ephemeral. The file is truncated on every launch and cleared
    // immediately when diagnostics are disabled; it is never retained across runs or while disabled.
    // Truncate at launch even when diagnostics are disabled, so an opt-out cannot leave old content behind.
    static func reset() {
        reset(fileURL: fileURL, diagnosticsEnabled: isEnabled)
    }

    /// The URL/flag overload keeps the retention contract independently testable without touching the
    /// user's real Application Support log.
    static func reset(fileURL: URL, diagnosticsEnabled: Bool) {
        clearLog(at: fileURL)
        guard diagnosticsEnabled else { return }
        appendToFile("=== diag start ===", at: fileURL)
    }

    /// Reconcile the file with the dynamic diagnostics setting (called on UserDefaults changes).
    static func applyRetentionPolicy() {
        guard !isEnabled else { return }
        clearLog()
    }

    private static func clearLog() {
        clearLog(at: fileURL)
    }

    private static func clearLog(at url: URL) {
        queue.sync {
            truncateLogFile(at: url)
        }
    }

    private static func truncateLogFile(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Owner-only (0600): the log may hold typed content when content-diag is on — never let it be
        // group/world-readable. createFile truncates + applies the perms in one step.
        FileManager.default.createFile(atPath: url.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        let safe = redactSecrets(message)
        logger.log("\(safe, privacy: .public)")
        appendToFile(safe)
    }

    // Raw typed content is file-only: unified logging must never receive key content. The autoclosure
    // also avoids extracting/building content when content diagnostics are off.
    static func logContent(_ message: @autoclosure () -> String) {
        guard isContentEnabled else { return }
        appendToFile(redactSecrets(message()))
    }

    private static func appendToFile(_ message: String, at url: URL = fileURL) {
        queue.async {
            let line = "\(timestamp()) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Builds key-content diagnostics only after the caller has positively ruled out a secure field.
    /// Keeping `characters` lazy makes the secure-field gate precede even the `InputEvent.chars` read.
    static func keyContentMessage(secureField: Bool,
                                  characters: @autoclosure () -> String) -> String? {
        guard !secureField, isContentEnabled else { return nil }
        return "keyDown chars=\"\(characters())\""
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
        // Every Authorization header, independent of casing or auth scheme. Use a replacement over
        // the whole string rather than `range(of:)`, which only scrubbed the first Bearer header.
        out = out.replacingOccurrences(
            of: #"(?i)(Authorization\s*:\s*)(?:(Bearer|Basic|Digest|Token)\s+)?[^\r\n]+"#,
            with: "$1$2 <redacted>",
            options: .regularExpression)
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
