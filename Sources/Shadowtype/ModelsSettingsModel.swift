import Cocoa
import SwiftUI

@MainActor
final class ModelsSettingsModel: ObservableObject {
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: String?
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloadError: String?
    @Published private(set) var engineLoaded = true
    @Published private(set) var engineLoadError: String?
    @Published var removeCandidate: ImportedModelEntry?
    @Published private(set) var freeDisk = ""
    @Published private(set) var importedEntries: [ImportedModelEntry] = []
    @Published private(set) var importError: String?
    @Published var hfSheetVisible = false

    private var pendingSwapID: String?
    private var selectionBeforeSwap: String?
    private let manager: ModelManager
    private let importedModelStore: ImportedModelStore
    private let physicalBytes: UInt64

    private static var modelsDir: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent("Shadowtype/models", isDirectory: true)
    }

    init(
        manager: ModelManager = ModelManager(),
        importedModelStore: ImportedModelStore = .shared,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.manager = manager
        self.importedModelStore = importedModelStore
        self.physicalBytes = physicalBytes
    }

    var removalFallbackEntry: ModelCatalogEntry {
        ModelCatalog.recommended(physicalBytes: physicalBytes)
    }

    var recommendedEntry: ModelCatalogEntry {
        ModelCatalog.recommended(physicalBytes: physicalBytes)
    }

    func selectedEntry(for selectedID: String) -> ModelCatalogEntry {
        if selectedID.hasPrefix("byom-"),
           let imported = importedEntries.first(where: { $0.id == selectedID }) {
            return imported.asCatalogEntry
        }
        return ModelCatalog.entries.first { $0.id == selectedID }
            ?? ModelCatalog.entries[0]
    }

    func modelURL(for entry: ModelCatalogEntry) -> URL {
        manager.modelURL(for: entry)
    }

    func modelFileExists(_ entry: ModelCatalogEntry) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: entry).path)
    }

    func fitsPhysicalMemory(_ entry: ModelCatalogEntry) -> Bool {
        ModelCatalog.ramOK(for: entry, physicalBytes: physicalBytes)
    }

    func confirmRemove(
        _ entry: ImportedModelEntry,
        selectedID: Binding<String>
    ) {
        let wasActive = entry.id == selectedID.wrappedValue
        importedModelStore.remove(id: entry.id)
        importedEntries = importedModelStore.entries()
        if wasActive {
            apply(to: removalFallbackEntry.id, selectedID: selectedID)
        }
    }

    func rescan() {
        var present: Set<String> = []
        for entry in ModelCatalog.entries
        where FileManager.default.fileExists(atPath: manager.modelURL(for: entry).path) {
            present.insert(entry.id)
        }
        installed = present
        freeDisk = Self.computeFreeDisk()
    }

    func reloadImportedEntries() {
        importedEntries = importedModelStore.entries()
    }

    func apply(to newID: String, selectedID: Binding<String>) {
        downloadError = nil
        downloadFraction = nil
        guard newID != selectedID.wrappedValue else { return }
        selectionBeforeSwap = selectedID.wrappedValue
        pendingSwapID = newID
        if newID.hasPrefix("byom-") {
            guard let imported = importedEntries.first(where: { $0.id == newID }) else {
                pendingSwapID = nil
                selectionBeforeSwap = nil
                return
            }
            selectedID.wrappedValue = newID
            NotificationCenter.default.post(
                name: .shadowtypeSelectModel,
                object: nil,
                userInfo: ["entry": imported.asCatalogEntry]
            )
            return
        }
        guard let entry = ModelCatalog.entries.first(where: { $0.id == newID }) else {
            pendingSwapID = nil
            selectionBeforeSwap = nil
            return
        }
        if !installed.contains(entry.id) {
            downloading = entry.id
        }
        selectedID.wrappedValue = newID
        NotificationCenter.default.post(
            name: .shadowtypeSelectModel,
            object: nil,
            userInfo: ["entry": entry]
        )
    }

    func importLocalGGUF() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import GGUF model"
        panel.prompt = "Import"
        if panel.runModal() != .OK, panel.url == nil { return }
        guard let source = panel.url else { return }

        if !ModelManager.isValidGGUF(source) {
            importError = "Not a valid GGUF file: \(source.lastPathComponent)"
            return
        }
        do {
            let linkedPath = try importedModelStore.createSymlink(from: source)
            let bytes = (
                try? FileManager.default.attributesOfItem(atPath: source.path)[.size]
                    as? NSNumber
            )?.int64Value ?? 0
            let approximateGB = Double(bytes) / (1024 * 1024 * 1024) * 1.1
            let entry = ImportedModelEntry(
                id: importedModelStore.generateID(),
                name: source.deletingPathExtension().lastPathComponent,
                fileName: (linkedPath as NSString).lastPathComponent,
                linkedPath: linkedPath,
                originalPath: source.path,
                approxRAMGB: approximateGB,
                source: .localFile,
                createdAt: Date()
            )
            importedModelStore.insert(entry)
            importedEntries = importedModelStore.entries()
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    func importedFromHuggingFace(
        _ entry: ImportedModelEntry,
        selectedID: Binding<String>
    ) {
        reloadImportedEntries()
        apply(to: entry.id, selectedID: selectedID)
    }

    func handleModelDidChange(
        _ notification: Notification,
        selectedID: Binding<String>
    ) {
        downloading = nil
        downloadFraction = nil
        rescan()
        let id = notification.userInfo?["id"] as? String
        let succeeded = notification.userInfo?["ok"] as? Bool != false
        if let id, !succeeded {
            downloadError = (notification.userInfo?["error"] as? String)
                ?? "Download failed — check disk space and network."
            if selectedID.wrappedValue == id,
               pendingSwapID == id,
               let prior = selectionBeforeSwap {
                selectedID.wrappedValue = prior
            }
        } else {
            downloadError = nil
        }
        if id == pendingSwapID {
            pendingSwapID = nil
            selectionBeforeSwap = nil
        }
    }

    func handleModelDownloadProgress(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? String,
              id == downloading else {
            return
        }
        downloadFraction = notification.userInfo?["fraction"] as? Double
    }

    func handleEngineLoadStateChanged(_ notification: Notification) {
        engineLoaded = notification.userInfo?["loaded"] as? Bool ?? true
        engineLoadError = engineLoaded
            ? nil
            : (notification.userInfo?["error"] as? String)
    }

    private static func computeFreeDisk() -> String {
        let url = modelsDir.deletingLastPathComponent()
        if let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return String(
                format: "%.1f GB free on disk",
                Double(bytes) / 1e9
            )
        }
        return ""
    }
}
