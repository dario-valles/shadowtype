import Cocoa
import ApplicationServices

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    var why: String {
        switch self {
        case .accessibility:
            return "Read the focused field's text + caret, and inject accepted words."
        case .inputMonitoring:
            return "Observe keystrokes to trigger completion and swallow the accept key."
        case .screenRecording:
            return "Optional — only for screen-aware (OCR) context. Not needed otherwise."
        }
    }

    var required: Bool { self != .screenRecording }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        )!
    }
}

@MainActor
final class SystemPermissionService {
    static let shared = SystemPermissionService()

    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        }
    }

    func allRequiredGranted() -> Bool {
        Permission.allCases
            .filter(\.required)
            .allSatisfy(isGranted)
    }

    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([option: true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func openSettings(_ permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
