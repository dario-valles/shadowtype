import Cocoa
import NaturalLanguage

final class CompletionGenerationSession {
    private let lock = NSLock()
    private var generation = 0

    var activePrefix = ""
    var isHealed = false
    var shellMode = false
    var committed = false
    var inContextRefire = false
    var rtl = false
    var caretRect: CGRect?
    var font: NSFont?
    var prefixLanguage: NLLanguage?
    var languageConstraints: [NLLanguage] = []
    var focusSeq: UInt64?
    var contextLanguage: NLLanguage?
    var lastSmartComposeProbeGeneration: Int?

    private(set) var pendingStreamSnapshot: String?
    private(set) var pendingStreamWork: DispatchWorkItem?
    let streamCoalesceWindow: TimeInterval = 0.033

    @discardableResult
    func bump() -> Int {
        lock.lock()
        generation &+= 1
        let value = generation
        lock.unlock()
        committed = false
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.lock()
        let matches = generation == candidate
        lock.unlock()
        return matches
    }

    func current() -> Int {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    func makeDeadlineWork(
        generation: Int,
        firstTokenSeen: @escaping () -> Bool,
        onExpire: @escaping () -> Void
    ) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self, !firstTokenSeen(), isCurrent(generation) else { return }
            onExpire()
        }
    }

    func clearPendingStream() {
        pendingStreamWork?.cancel()
        pendingStreamWork = nil
        pendingStreamSnapshot = nil
    }

    func coalesce(
        snapshot: String,
        generation: Int,
        render: @escaping (String) -> Void
    ) {
        pendingStreamSnapshot = snapshot
        guard pendingStreamWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingStreamWork = nil
            guard let pending = pendingStreamSnapshot else { return }
            pendingStreamSnapshot = nil
            guard isCurrent(generation) else { return }
            render(pending)
        }
        pendingStreamWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + streamCoalesceWindow,
            execute: work
        )
    }

    func takePendingStream() -> String? {
        guard let snapshot = pendingStreamSnapshot else { return nil }
        pendingStreamWork?.cancel()
        pendingStreamWork = nil
        pendingStreamSnapshot = nil
        return snapshot
    }
}
