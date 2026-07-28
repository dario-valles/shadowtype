// UpdateManager — homegrown in-app auto-update (the "out-of-the-box" updater; no Sparkle).
//
// Why roll our own: the app is already running and already TCC-trusted under a stable code identity,
// so it can update ITSELF in place — fetch a manifest from GitHub Releases, download the new build,
// verify its signed manifest + SHA-256, Gatekeeper-assess, atomically swap its own bundle, and
// relaunch. Developer-ID + notarization on the release zip is what lets the swapped bundle clear
// Gatekeeper; the manifest's SHA-256 pins the exact archive bytes so a tampered CDN object is rejected.
//
// Shadowtype is open source and free: releases live on this repo's own GitHub Releases. There is NO
// Worker or license revocation. The `latest.json` asset is an Ed25519-signed payload envelope; the
// embedded release public key and Apple's notarized code identity are independent trust anchors.
//
// The toggle: `shadowtype.autoCheckUpdates` gates the launch + periodic check (AppDelegate);
// `shadowtype.includeBetaBuilds` selects the channel. Manual "Check for Updates…" ignores the toggle.
import Foundation
import CryptoKit
import AppKit
import Darwin

/// Release channel selected by the "Include beta builds" toggle. Beta = GitHub --prerelease.
enum UpdateChannel: String {
    case stable
    case beta
}

/// Decoded update manifest — the `latest.json` asset attached to each GitHub release. Keys match the
/// release-contract schema exactly. `minBuild` drives the mandatory-update gate (builds below it must
/// update). `build` (CFBundleVersion) is the ONLY ordering key.
struct UpdateManifest: Decodable, Equatable {
    let version: String      // marketing version, e.g. "0.2.2" (CFBundleShortVersionString)
    let build: Int           // monotonic build number (CFBundleVersion); the ONLY ordering key
    let channel: String      // "stable" | "beta"
    let url: String          // https URL of the notarized+stapled .zip (ditto --keepParent of the .app)
    let sha256: String       // lowercase hex SHA-256 of the .zip; pins the archive to the manifest
    let minBuild: Int        // builds < minBuild are forced to update (mandatory); camelCase in latest.json
    let notes: String        // human release notes (shown in About / menu)
}

private struct SignedManifestEnvelope: Decodable {
    let payload: String
    let signature: String
}

@MainActor
final class UpdateManager: ObservableObject {
    /// Observable update state for the About pane + menu bar.
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)        // newer build found, not yet downloaded
        case downloading(Double?)             // 0…1, or nil when the server sends no length
        case readyToInstall(UpdateManifest)   // staged + verified; one click swaps + relaunches
        case failed(String)
    }

    static let shared = UpdateManager()

    @Published private(set) var state: State = .idle
    /// The newest manifest we've seen this session (drives the menu "Install vX…" item even after the
    /// About pane recomputes). nil until a check finds something newer.
    @Published private(set) var pendingManifest: UpdateManifest?

    private let apiBase: URL                  // https://api.github.com/repos/<owner>/<repo>
    private let session: URLSession
    private let defaults: UserDefaults
    private let manifestPublicKey: Data
    private let allowedHosts: Set<String>
    private let runningBuild: Int
    private var stagedUpdate: StagedUpdate?

    private struct StagedUpdate {
        let rootURL: URL
        let archiveURL: URL
        let manifest: UpdateManifest
    }

    // Production: the public repo's GitHub API base. Tests inject a stub origin/session.
    private init() {
        self.apiBase = UpdateManager.defaultAPIBase
        self.session = .shared
        self.defaults = .standard
        self.manifestPublicKey = UpdateManager.releaseManifestPublicKey
        self.allowedHosts = UpdateManager.productionAllowedHosts
        self.runningBuild = UpdateManager.currentBuild()
        Self.raiseHighWater(in: .standard, to: UpdateManager.currentBuild())
        Self.cleanStaleWorkDirectories(installParent: Bundle.main.bundleURL.deletingLastPathComponent())
    }

    /// Test seam — inject a stub GitHub-API base + session (+ defaults) so the check can be
    /// exercised hermetically.
    init(apiBase: URL, session: URLSession = .shared, defaults: UserDefaults = .standard,
         manifestPublicKey: Data? = nil, allowedHosts: Set<String>? = nil,
         runningBuild: Int? = nil) {
        let resolvedRunningBuild = runningBuild ?? UpdateManager.currentBuild()
        self.apiBase = apiBase
        self.session = session
        self.defaults = defaults
        self.manifestPublicKey = manifestPublicKey ?? UpdateManager.releaseManifestPublicKey
        self.allowedHosts = allowedHosts ?? UpdateManager.productionAllowedHosts
        self.runningBuild = resolvedRunningBuild
        Self.raiseHighWater(in: defaults, to: resolvedRunningBuild)
    }

    /// The public repo that hosts releases (per the release/update contract).
    static let repoSlug = "dario-valles/shadowtype"
    static let defaultAPIBase = URL(string: "https://api.github.com/repos/\(repoSlug)")!
    /// GitHub's API requires a User-Agent on every request.
    static let userAgent = "Shadowtype-Updater"
    static let autoCheckKey = "shadowtype.autoCheckUpdates"
    static let highWaterBuildKey = "shadowtype.update.highWaterBuild"
    static let releaseManifestPublicKey = Data(base64Encoded:
        "7qJ/CyY2wJRRpD6QUtHaBz8Pajg35mZzctBogY3JTVo=")!
    static let productionAllowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    /// Persisted across launches: a mandatory (minBuild-forced) update was detected but not yet
    /// installed. AppDelegate reads `hasPendingMandatoryUpdate` at launch to prompt synchronously
    /// instead of waiting minutes for the first periodic check. Set/cleared by check() (mandatory vs
    /// optional/up-to-date) and cleared by installAndRelaunch() once the swap is handed off.
    static let mandatoryPendingKey = "shadowtype.update.mandatoryPending"
    static var hasPendingMandatoryUpdate: Bool {
        let defaults = UserDefaults.standard
        let enabled = (defaults.object(forKey: autoCheckKey) as? Bool) ?? true
        return enabled && defaults.bool(forKey: mandatoryPendingKey)
    }

    // MARK: - Current build

    /// This running app's build number (CFBundleVersion). The single ordering key for "is X newer".
    /// Falls back to 0 so a malformed/absent value never blocks a legitimate update.
    static func currentBuild() -> Int {
        guard let s = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, let n = Int(s) else {
            return 0
        }
        return n
    }

    // MARK: - Check

    /// Hit the GitHub Releases API, locate the chosen release's `latest.json` asset, parse it, and decide
    /// whether it's newer than us. Pure of side effects beyond `state`/`pendingManifest`. `manual` only
    /// changes the terminal copy (a manual check says "up to date"; a silent launch check goes to idle).
    @discardableResult
    func check(channel: UpdateChannel, manual: Bool) async -> UpdateManifest? {
        if !manual && !automaticChecksEnabled {
            state = .idle
            return nil
        }
        state = .checking
        do {
            // nil → nothing published for this channel: we're up to date.
            guard let manifest = try await fetchManifest(channel: channel),
                  Self.isBuildEligible(manifestBuild: manifest.build, stagedBuild: manifest.build,
                                       runningBuild: runningBuild, highWaterBuild: highWaterBuild) else {
                state = manual ? .upToDate : .idle
                clearPending()
                defaults.set(false, forKey: Self.mandatoryPendingKey)
                return nil
            }
            // A newer build exists — but DON'T reveal the menu/"install" affordance yet: it isn't
            // installable until downloadAndStage succeeds (post .shadowtypeUpdateAvailable there).
            pendingManifest = manifest
            state = .available(manifest)
            defaults.set(isMandatory(manifest), forKey: Self.mandatoryPendingKey)
            return manifest
        } catch {
            state = manual ? .failed(Self.message(for: error)) : .idle
            return nil
        }
    }

    /// Clear the pending manifest and hide any stale menu "Install Update…" affordance (object nil).
    private func clearPending() {
        pendingManifest = nil
        NotificationCenter.default.post(name: .shadowtypeUpdateAvailable, object: nil)
    }

    /// True when the running build is below the newest manifest's `minBuild` — the update is mandatory.
    func isMandatory(_ manifest: UpdateManifest) -> Bool {
        runningBuild < manifest.minBuild
    }

    private var automaticChecksEnabled: Bool {
        (defaults.object(forKey: Self.autoCheckKey) as? Bool) ?? true
    }

    private var highWaterBuild: Int {
        defaults.integer(forKey: Self.highWaterBuildKey)
    }

    private static func raiseHighWater(in defaults: UserDefaults, to build: Int) {
        guard build > defaults.integer(forKey: highWaterBuildKey) else { return }
        defaults.set(build, forKey: highWaterBuildKey)
    }

    // MARK: - GitHub Releases fetch

    /// A single GitHub release asset (only the two fields we need).
    struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// A single GitHub release (only the fields we need).
    struct GitHubRelease: Decodable {
        let prerelease: Bool
        let draft: Bool
        let assets: [GitHubAsset]
    }

    /// Resolve the chosen channel's release, find its `latest.json` asset, download + parse it.
    /// - stable → GET /releases/latest (GitHub's "latest non-prerelease, non-draft" endpoint).
    /// - beta   → GET /releases (first non-draft entry, which includes prereleases).
    /// Returns nil when there's no published release / no `latest.json` asset (treated as up-to-date).
    private func fetchManifest(channel: UpdateChannel) async throws -> UpdateManifest? {
        let release: GitHubRelease?
        switch channel {
        case .stable:
            release = try await fetchLatestStableRelease()
        case .beta:
            release = try await fetchFirstRelease()
        }
        guard let release,
              let asset = release.assets.first(where: { $0.name == "latest.json" }),
              let assetURL = URL(string: asset.browserDownloadURL) else {
            return nil
        }
        try Self.validateManifestAssetURL(assetURL, allowedHosts: allowedHosts)
        let data = try await getData(from: assetURL)
        let manifest = try Self.decodeSignedManifest(data, publicKey: manifestPublicKey)
        try Self.validateManifest(manifest, for: channel, allowedHosts: allowedHosts)
        return manifest
    }

    private func fetchLatestStableRelease() async throws -> GitHubRelease? {
        let url = apiBase.appendingPathComponent("releases/latest")
        let data = try await getData(from: url, accept: "application/vnd.github+json")
        return try? JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func fetchFirstRelease() async throws -> GitHubRelease? {
        let url = apiBase.appendingPathComponent("releases")
        let data = try await getData(from: url, accept: "application/vnd.github+json")
        let releases = (try? JSONDecoder().decode([GitHubRelease].self, from: data)) ?? []
        // First non-draft entry — GitHub returns releases newest-first, prereleases included.
        return releases.first(where: { !$0.draft && $0.prerelease })
    }

    /// GET with the required User-Agent header (and optional Accept). No auth token (public repo).
    /// 404 (no `releases/latest` published yet) → treated as "nothing published": returns empty Data so
    /// the JSON decode yields nil and the caller reports up-to-date rather than a scary error.
    private func getData(from url: URL, accept: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let redirectDelegate = RedirectValidationDelegate(allowedHosts: allowedHosts)
        let (data, resp) = try await session.data(for: req, delegate: redirectDelegate)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 404 { return Data() }   // nothing published → up to date
        guard (200...299).contains(http.statusCode) else { throw UpdateError.badResponse }
        guard let finalURL = http.url,
              Self.isAllowedRedirectURL(finalURL, allowedHosts: allowedHosts) else {
            throw UpdateError.untrustedURL
        }
        return data
    }

    static func decodeSignedManifest(_ data: Data, publicKey: Data) throws -> UpdateManifest {
        let envelope: SignedManifestEnvelope
        do {
            envelope = try JSONDecoder().decode(SignedManifestEnvelope.self, from: data)
        } catch {
            throw UpdateError.invalidManifest
        }
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else {
            throw UpdateError.invalidManifestSignature
        }
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: payload)
        } catch {
            throw UpdateError.invalidManifest
        }
    }

    static func validateManifest(_ manifest: UpdateManifest, for channel: UpdateChannel,
                                 allowedHosts: Set<String>? = nil) throws {
        let allowedHosts = allowedHosts ?? productionAllowedHosts
        guard manifest.channel == channel.rawValue,
              (1...Int(Int32.max)).contains(manifest.build),
              (0...manifest.build).contains(manifest.minBuild),
              manifest.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              manifest.version.range(of: "^[0-9A-Za-z][0-9A-Za-z.-]{0,63}$",
                                     options: .regularExpression) != nil,
              !manifest.version.contains(".."),
              let url = URL(string: manifest.url),
              isAllowedInitialURL(url, allowedHosts: allowedHosts) else {
            throw UpdateError.invalidManifest
        }
        if allowedHosts == productionAllowedHosts && url.host?.lowercased() != "github.com" {
            throw UpdateError.invalidManifest
        }
        let expectedPath = "/\(repoSlug)/releases/download/v\(manifest.version)/Shadowtype-\(manifest.version)-\(manifest.build).zip"
        guard url.path == expectedPath else { throw UpdateError.invalidManifest }
    }

    static func isAllowedRedirectURL(_ url: URL, allowedHosts: Set<String>? = nil) -> Bool {
        let allowedHosts = allowedHosts ?? productionAllowedHosts
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), allowedHosts.contains(host) else { return false }
        return true
    }

    private static func isAllowedInitialURL(_ url: URL, allowedHosts: Set<String>) -> Bool {
        isAllowedRedirectURL(url, allowedHosts: allowedHosts) &&
            url.query == nil && url.fragment == nil
    }

    private static func validateManifestAssetURL(_ url: URL, allowedHosts: Set<String>) throws {
        guard isAllowedInitialURL(url, allowedHosts: allowedHosts) else {
            throw UpdateError.untrustedURL
        }
        if allowedHosts == productionAllowedHosts && url.host?.lowercased() != "github.com" {
            throw UpdateError.untrustedURL
        }
        let prefix = "/\(repoSlug)/releases/download/"
        guard url.path.hasPrefix(prefix), url.lastPathComponent == "latest.json" else {
            throw UpdateError.untrustedURL
        }
    }

    // MARK: - Download + stage

    /// Download the manifest's zip, verify its SHA-256 against the manifest, unzip, strip quarantine,
    /// and codesign-verify the staged bundle. On success → `.readyToInstall`.
    func downloadAndStage(_ manifest: UpdateManifest) async {
        cleanStagedUpdate()
        do {
            guard let channel = UpdateChannel(rawValue: manifest.channel) else {
                throw UpdateError.invalidManifest
            }
            try Self.validateManifest(manifest, for: channel, allowedHosts: allowedHosts)
            guard Self.isBuildEligible(manifestBuild: manifest.build, stagedBuild: manifest.build,
                                       runningBuild: runningBuild, highWaterBuild: highWaterBuild) else {
                throw UpdateError.rollback
            }
        } catch {
            state = .failed("Invalid update URL."); clearPending(); return
        }
        guard let url = URL(string: manifest.url) else {
            state = .failed("Invalid update URL."); clearPending(); return
        }
        state = .downloading(nil)
        do {
            let zipURL = try await download(from: url) { [weak self] p in
                Task { @MainActor in self?.state = .downloading(p) }
            }
            defer { try? FileManager.default.removeItem(at: zipURL) }

            let digest = try Self.sha256Hex(of: zipURL)
            guard digest == manifest.sha256 else {
                state = .failed("Update failed integrity check."); clearPending(); return
            }
            let verified = try Self.unzipAndVerify(
                zipURL, manifest: manifest, runningBuild: runningBuild,
                highWaterBuild: highWaterBuild
            )
            let retainedArchive = verified.rootURL.appendingPathComponent("update.zip")
            do {
                try FileManager.default.moveItem(at: zipURL, to: retainedArchive)
            } catch {
                try? FileManager.default.removeItem(at: verified.rootURL)
                throw error
            }
            stagedUpdate = StagedUpdate(rootURL: verified.rootURL, archiveURL: retainedArchive,
                                        manifest: manifest)
            pendingManifest = manifest
            state = .readyToInstall(manifest)
            // Only NOW is the update actually installable — reveal the menu "Install Update vX…" item.
            NotificationCenter.default.post(name: .shadowtypeUpdateAvailable, object: manifest)
        } catch {
            cleanStagedUpdate()
            state = .failed(Self.message(for: error))
            clearPending()
        }
    }

    /// Convenience for the toggle-driven path / menu: check → if newer, download+stage in one call.
    func checkThenStage(channel: UpdateChannel, manual: Bool) async {
        if let manifest = await check(channel: channel, manual: manual) {
            await downloadAndStage(manifest)
        }
    }

    // URLSession download with progress + atomic move to a temp file we own. Lifts the proven shape from
    // ModelManager.download (URLSessionDownloadDelegate progress + 200…299 check).
    private func download(from url: URL, onProgress: @escaping (Double?) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(allowedHosts: allowedHosts, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await session.download(for: req, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.serverError(http.statusCode)
        }
        guard let finalURL = response.url,
              Self.isAllowedRedirectURL(finalURL, allowedHosts: allowedHosts) else {
            throw UpdateError.untrustedURL
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-update-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // Chunked SHA-256 — identical to ModelManager.sha256Hex.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Unzip with `ditto -x -k`, then verify build, code identity, and Gatekeeper policy. Quarantine is
    // removed only after the notarization assessment succeeds.
    private static func unzipAndVerify(_ zipURL: URL, manifest: UpdateManifest, runningBuild: Int,
                                       highWaterBuild: Int,
                                       rootURL: URL? = nil) throws -> (rootURL: URL, appURL: URL) {
        let dir = rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: dir) } }
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])

        let apps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first, app.lastPathComponent == "Shadowtype.app" else {
            throw UpdateError.badArchive
        }
        try verifyCandidateApp(app, manifest: manifest, runningBuild: runningBuild,
                               highWaterBuild: highWaterBuild)
        succeeded = true
        return (dir, app)
    }

    private static func verifyCandidateApp(_ app: URL, manifest: UpdateManifest, runningBuild: Int,
                                           highWaterBuild: Int) throws {
        guard let stagedBuild = appBuild(at: app),
              isBuildEligible(manifestBuild: manifest.build, stagedBuild: stagedBuild,
                              runningBuild: runningBuild, highWaterBuild: highWaterBuild) else {
            throw UpdateError.buildMismatch
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // TCC CONTINUITY GUARD: macOS anchors Screen Recording / Accessibility grants to the recorded
        // code requirement (Team + bundle id), NOT the cdhash — so a same-identity update keeps every
        // grant, but a build signed by a DIFFERENT team (or self-signed / ad-hoc, which has no stable
        // anchor) silently revokes them and re-prompts the user on every launch. Refuse to install such
        // a build rather than nuke the user's permissions out from under them.
        guard isSignatureContinuous(running: signingIdentity(of: Bundle.main.bundlePath),
                                    staged: signingIdentity(of: app.path)) else {
            throw UpdateError.signatureMismatch
        }
        if let requirement = designatedRequirement(of: Bundle.main.bundlePath) {
            try run("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", app.path])
        }
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    }

    static func appBuild(at app: URL) -> Int? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              let value = plist["CFBundleVersion"] as? String,
              value.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil else { return nil }
        return Int(value)
    }

    static func isBuildEligible(manifestBuild: Int, stagedBuild: Int?, runningBuild: Int,
                                highWaterBuild: Int) -> Bool {
        guard let stagedBuild else { return false }
        return stagedBuild == manifestBuild &&
            manifestBuild > 0 &&
            manifestBuild > runningBuild &&
            manifestBuild > highWaterBuild
    }

    /// (team, identifier) read from a bundle's code signature, or nil if unsigned / ad-hoc (no Team).
    /// `codesign -dv` writes these fields to STDERR as `Identifier=…` / `TeamIdentifier=…`.
    static func signingIdentity(of bundlePath: String) -> (team: String, identifier: String)? {
        let out = (try? captureStderr("/usr/bin/codesign", ["-dv", bundlePath])) ?? ""
        func field(_ key: String) -> String? {
            for line in out.split(separator: "\n") where line.hasPrefix(key + "=") {
                return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        guard let id = field("Identifier"), !id.isEmpty,
              let team = field("TeamIdentifier"), team != "not set", !team.isEmpty else { return nil }
        return (team, id)
    }

    static func designatedRequirement(of bundlePath: String) -> String? {
        let out = (try? captureStderr("/usr/bin/codesign", ["-dr", "-", bundlePath])) ?? ""
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("designated => ") })
        else { return nil }
        return String(line.dropFirst("designated => ".count))
    }

    /// Pure decision: may we swap `staged` over `running` without losing TCC grants? A nil `running`
    /// (the live app is itself a self-signed dev build — no anchored grants to protect) permits the
    /// install. Otherwise the staged build MUST carry the same Team + identifier, and must itself be
    /// properly team-signed (non-nil). Factored out of `unzipAndVerify` so it's unit-testable without
    /// a real signed bundle.
    static func isSignatureContinuous(running: (team: String, identifier: String)?,
                                      staged: (team: String, identifier: String)?) -> Bool {
        guard let running else { return true }
        guard let staged else { return false }
        return staged.team == running.team && staged.identifier == running.identifier
    }

    // MARK: - Install + relaunch

    enum InstallFaultPoint: CaseIterable {
        case candidatePrepared
        case candidateVerified
        case beforeExchange
        case afterExchange
        case cleanupScheduled
    }

    /// Re-hash + freshly extract the retained archive, verify the exact incoming bundle, atomically
    /// exchange it with the running bundle, then hand only cleanup/relaunch to a detached helper.
    func installAndRelaunch() {
        guard let staged = stagedUpdate else { state = .failed("No staged update."); return }
        let destination = Bundle.main.bundleURL
        let installRoot = destination.deletingLastPathComponent()
            .appendingPathComponent(".shadowtype-install-\(UUID().uuidString)", isDirectory: true)
        var exchanged = false
        do {
            guard try Self.sha256Hex(of: staged.archiveURL) == staged.manifest.sha256 else {
                throw UpdateError.integrityMismatch
            }
            let verified = try Self.unzipAndVerify(
                staged.archiveURL, manifest: staged.manifest, runningBuild: runningBuild,
                highWaterBuild: highWaterBuild, rootURL: installRoot
            )
            try Self.performAtomicExchange(
                candidate: verified.appURL, destination: destination,
                verify: {
                    guard try Self.sha256Hex(of: staged.archiveURL) == staged.manifest.sha256 else {
                        throw UpdateError.integrityMismatch
                    }
                    try Self.verifyCandidateApp(
                        $0, manifest: staged.manifest, runningBuild: runningBuild,
                        highWaterBuild: highWaterBuild
                    )
                }
            )
            exchanged = true
            Self.raiseHighWater(in: defaults, to: staged.manifest.build)
            cleanStagedUpdate()
            let script = try Self.writeRelaunchScript(oldRoot: installRoot)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script, String(ProcessInfo.processInfo.processIdentifier),
                           destination.path, installRoot.path]
            try p.run()
            defaults.set(false, forKey: Self.mandatoryPendingKey)
            NSApp.terminate(nil)
        } catch {
            cleanStagedUpdate()
            if !exchanged { try? FileManager.default.removeItem(at: installRoot) }
            state = .failed(Self.message(for: error))
        }
    }

    /// Testable transaction boundary. `RENAME_SWAP` is a single filesystem operation: before it the
    /// destination is the old working app; after it the destination is the new working app.
    @discardableResult
    static func performAtomicExchange(
        candidate: URL, destination: URL,
        faultAt: InstallFaultPoint? = nil,
        verify: (URL) throws -> Void
    ) throws -> Bool {
        if faultAt == .candidatePrepared { return false }
        try verify(candidate)
        if faultAt == .candidateVerified || faultAt == .beforeExchange { return false }
        let result = destination.path.withCString { destinationPath in
            candidate.path.withCString { candidatePath in
                renameatx_np(AT_FDCWD, destinationPath, AT_FDCWD, candidatePath,
                             UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw UpdateError.atomicSwapFailed(errno) }
        if faultAt == .afterExchange || faultAt == .cleanupScheduled { return false }
        return true
    }

    // The old running app lives under oldRoot after the atomic exchange. Wait for this process to
    // exit before deleting it; failure here cannot remove or corrupt the newly installed destination.
    private static func writeRelaunchScript(oldRoot _: URL) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-relaunch-\(UUID().uuidString).sh")
        let wrapper = #"""
        #!/bin/sh
        pid="$1"; dest="$2"; oldroot="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$oldroot"
        open "$dest"
        rm -f "$0"
        """#
        try wrapper.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func cleanStagedUpdate() {
        if let root = stagedUpdate?.rootURL { try? FileManager.default.removeItem(at: root) }
        stagedUpdate = nil
    }

    private static func cleanStaleWorkDirectories(installParent: URL) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        if let entries = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("shadowtype-staged-") {
                try? fm.removeItem(at: entry)
            }
        }
        if let entries = try? fm.contentsOfDirectory(at: installParent, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(".shadowtype-install-") {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Process helper

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.toolFailed(launchPath, p.terminationStatus) }
        return p.terminationStatus
    }

    /// Run a tool and capture its STDERR (where `codesign -dv` emits its fields). Output is tiny, so
    /// read-to-EOF then wait can't deadlock on the 64 KB pipe buffer.
    private static func captureStderr(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Errors

    enum UpdateError: Error {
        case badResponse, badArchive, signatureMismatch, serverError(Int), toolFailed(String, Int32)
        case invalidManifest, invalidManifestSignature, untrustedURL
        case rollback, buildMismatch, integrityMismatch, atomicSwapFailed(Int32)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case UpdateError.badArchive: return "Downloaded update was malformed."
        case UpdateError.signatureMismatch:
            return "Update was signed by a different identity and was not installed."
        case UpdateError.invalidManifest, UpdateError.invalidManifestSignature:
            return "Update manifest failed authentication."
        case UpdateError.rollback, UpdateError.buildMismatch:
            return "Update build was invalid or has already been installed."
        case UpdateError.integrityMismatch:
            return "Update failed integrity check."
        case UpdateError.atomicSwapFailed:
            return "Update could not be exchanged safely."
        case UpdateError.badResponse, UpdateError.serverError: return "Couldn't reach the update server."
        default: return "Update failed. Please try again."
        }
    }
}

// Reused download-progress delegate (a copy of ModelManager.DownloadDelegate — the async download(_:)
// API consumes the temp file itself, so didFinishDownloadingTo is a no-op).
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let allowedHosts: Set<String>
    private let onProgress: (Double?) -> Void
    init(allowedHosts: Set<String>, onProgress: @escaping (Double?) -> Void) {
        self.allowedHosts = allowedHosts
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            onProgress(nil)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allows(request.url, hosts: allowedHosts) ? request : nil)
    }

    private static func allows(_ url: URL?, hosts: Set<String>) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }
}

private final class RedirectValidationDelegate: NSObject, URLSessionTaskDelegate {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
