import Cocoa
import SwiftUI

@MainActor
final class PermissionsManager: ObservableObject {
    @Published var granted: [Permission: Bool] = [:]
    @Published var relaunchError: String?

    private let systemPermissionService: SystemPermissionService
    private let screenOCROptInPrompter: ScreenOCROptInPrompter
    private var relaunchTask: Process?

    convenience init() {
        self.init(
            systemPermissionService: .shared,
            screenOCROptInPrompter: ScreenOCROptInPrompter()
        )
    }

    init(
        systemPermissionService: SystemPermissionService,
        screenOCROptInPrompter: ScreenOCROptInPrompter
    ) {
        self.systemPermissionService = systemPermissionService
        self.screenOCROptInPrompter = screenOCROptInPrompter
        refresh()
    }

    static func isGranted(_ permission: Permission) -> Bool {
        SystemPermissionService.shared.isGranted(permission)
    }

    static func allRequiredGranted() -> Bool {
        SystemPermissionService.shared.allRequiredGranted()
    }

    func refresh() {
        var next: [Permission: Bool] = [:]
        for permission in Permission.allCases {
            next[permission] = systemPermissionService.isGranted(permission)
        }
        granted = next
        screenOCROptInPrompter.permissionStateChanged(
            isGranted: next[.screenRecording] ?? false
        )
    }

    func request(_ permission: Permission) {
        systemPermissionService.request(permission)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    func openSettings(_ permission: Permission) {
        systemPermissionService.openSettings(permission)
    }

    func relaunch() {
        guard relaunchTask == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.relaunchTask = nil
                guard process.terminationReason == .exit,
                      process.terminationStatus == 0 else {
                    self?.relaunchError =
                        "Couldn’t relaunch (open exited with status \(process.terminationStatus))."
                    Diag.log(
                        "relaunch failed: open exited with status \(process.terminationStatus)"
                    )
                    return
                }
                self?.relaunchError = nil
                NSApp.terminate(nil)
            }
        }
        do {
            relaunchTask = task
            try task.run()
            relaunchError = nil
        } catch {
            relaunchTask = nil
            relaunchError = "Couldn’t relaunch: \(error.localizedDescription)"
            Diag.log("relaunch failed: \(error.localizedDescription)")
        }
    }
}
