import Cocoa

@MainActor
final class ApplicationMetadataProvider {
    typealias ApplicationURLResolver = (String) -> URL?
    typealias DisplayNameResolver = (String) -> String
    typealias IconResolver = (String) -> NSImage

    static let shared = ApplicationMetadataProvider()

    private let applicationURL: ApplicationURLResolver
    private let displayNameAtPath: DisplayNameResolver
    private let iconForFile: IconResolver
    private var nameCache: [String: String] = [:]
    private var iconCache: [String: NSImage?] = [:]
    private var installedCache: [String: Bool] = [:]

    init(
        applicationURL: @escaping ApplicationURLResolver = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        displayNameAtPath: @escaping DisplayNameResolver = {
            FileManager.default.displayName(atPath: $0)
        },
        iconForFile: @escaping IconResolver = {
            NSWorkspace.shared.icon(forFile: $0)
        }
    ) {
        self.applicationURL = applicationURL
        self.displayNameAtPath = displayNameAtPath
        self.iconForFile = iconForFile
    }

    func displayName(_ bundleId: String) -> String {
        if let cached = nameCache[bundleId] { return cached }
        let name: String
        if let url = applicationURL(bundleId) {
            name = displayNameAtPath(url.path)
        } else if let last = bundleId.split(separator: ".").last {
            name = String(last)
        } else {
            name = bundleId
        }
        nameCache[bundleId] = name
        return name
    }

    func icon(_ bundleId: String) -> NSImage? {
        if let cached = iconCache[bundleId] { return cached }
        let image = applicationURL(bundleId).map { iconForFile($0.path) }
        iconCache[bundleId] = image
        return image
    }

    func isInstalled(_ bundleId: String) -> Bool {
        if let cached = installedCache[bundleId] { return cached }
        let installed = applicationURL(bundleId) != nil
        installedCache[bundleId] = installed
        return installed
    }
}
