import Foundation

final class LocalAPIRuntimeController {
    private let localAPI: LocalAPIServer
    private let statusItem: StatusItemController

    init(localAPI: LocalAPIServer, statusItem: StatusItemController) {
        self.localAPI = localAPI
        self.statusItem = statusItem
    }

    func configure(coordinator: CompletionCoordinator, modelManager: ModelManager) {
        localAPI.coordinator = coordinator
        localAPI.modelManager = modelManager
        if UserDefaults.standard.bool(forKey: "shadowtype.serverEnabled") {
            startLocalAPIIfNeeded()
        }
        refreshLocalAPIMenu()
    }

    func applyLocalAPIToggle() {
        let wantOn = UserDefaults.standard.bool(forKey: "shadowtype.serverEnabled")
        if wantOn {
            startLocalAPIIfNeeded()
        } else if localAPI.isRunning {
            localAPI.stop()
            NotificationCenter.default.post(name: .shadowtypeLocalAPIDidChange, object: nil)
        }
        refreshLocalAPIMenu()
    }

    private func startLocalAPIIfNeeded() {
        guard !localAPI.isRunning else { return }
        _ = APIKeyStore.ensureAPIKey()
        if localAPI.start() != nil {
            UserDefaults.standard.removeObject(forKey: "shadowtype.localAPI.lastError")
            NotificationCenter.default.post(name: .shadowtypeLocalAPIDidChange, object: nil)
            Diag.log("localAPI: started on port \(localAPI.boundPort ?? -1)")
        } else {
            UserDefaults.standard.set(
                localAPI.lastError ?? "Could not start the local API server.",
                forKey: "shadowtype.localAPI.lastError")
            NotificationCenter.default.post(name: .shadowtypeLocalAPIDidChange, object: nil)
            Diag.log("localAPI: start failed (\(localAPI.lastError ?? "unknown"))")
        }
        refreshLocalAPIMenu()
    }

    func refreshLocalAPIMenu() {
        statusItem.setLocalAPI(
            on: localAPI.isRunning,
            port: localAPI.boundPort,
            available: true)
        if localAPI.isRunning, let port = localAPI.boundPort {
            UserDefaults.standard.set(port, forKey: "shadowtype.lastBoundPort")
        } else {
            UserDefaults.standard.removeObject(forKey: "shadowtype.lastBoundPort")
        }
    }
}
