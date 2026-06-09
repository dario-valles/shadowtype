// ClipboardContextProvider — FR-CTX-2 clipboard-aware context (Paid tier).
// Reads the general NSPasteboard's string and offers it as optional leading prompt context.
// Unlike OCR (FR-CTX-1), a pasteboard read is cheap and synchronous, so there is no capture/throttle
// machinery here — each call simply samples the current pasteboard string. Results are transient and
// NEVER written to disk. Degrades to nil whenever the pasteboard holds no usable string. The integrator
// gates this behind CompletionCoordinator.isLicensed + a user toggle (off by default).
import AppKit
import Foundation

final class ClipboardContextProvider {
    // The pasteboard to sample. Injectable so tests use a private, unique-named NSPasteboard instead of
    // touching the shared system clipboard (.general) — that is the hermetic seam.
    private let pasteboard: NSPasteboard

    // Last NSPasteboard.changeCount we observed, guarded for cross-thread sampling. The system bumps
    // changeCount on every write, so comparing it lets callers cheaply tell whether the clipboard
    // changed since we last looked, without re-reading (and re-clamping) the full string.
    private let stateLock = NSLock()
    private var lastChangeCount: Int

    // Designated init. Defaults to the system-wide general pasteboard for production; tests inject a
    // unique-named NSPasteboard so they never read or mutate the real clipboard.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    // Returns the current general-pasteboard string (trimmed of surrounding whitespace/newlines and
    // capped to the most recent `maxChars`), or nil if the pasteboard holds no usable string. Sampling
    // also records the pasteboard's changeCount so a later `hasChanged` reflects this read.
    func recentText(maxChars: Int) -> String? {
        guard maxChars > 0 else { return nil }
        let count = pasteboard.changeCount
        storeChangeCount(count)
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.clamp(trimmed, to: maxChars)
    }

    // Cheap check: has the pasteboard been written to since we last sampled it (via recentText or init)?
    // Reads only the integer changeCount — it does not fetch or clamp the string.
    var hasChanged: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return pasteboard.changeCount != lastChangeCount
    }

    private func storeChangeCount(_ count: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        lastChangeCount = count
    }

    // MARK: Helpers

    // Keep the most recent text by clamping to the tail (mirrors ScreenContextProvider.clamp): the
    // clipboard's content is treated as leading context, and the tail is the freshest portion when the
    // copied text exceeds the budget. nil when empty so callers can skip the context block entirely.
    static func clamp(_ text: String?, to maxChars: Int) -> String? {
        guard let text, !text.isEmpty, maxChars > 0 else { return nil }
        if text.count <= maxChars { return text }
        return String(text.suffix(maxChars))
    }
}
