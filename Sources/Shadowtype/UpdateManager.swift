// UpdateManager — homegrown in-app auto-update (the "out-of-the-box" updater; no Sparkle).
//
// Why roll our own: the app is already running and already TCC-trusted under a stable code identity,
// so it can update ITSELF in place — fetch a manifest from GitHub Releases, download the new build,
// verify its SHA-256, strip the download quarantine, codesign-verify, swap its own bundle, and
// relaunch. Developer-ID + notarization on the release zip is what lets the swapped bundle clear
// Gatekeeper; the manifest's SHA-256 pins the exact archive bytes so a tampered CDN object is rejected.
//
// Shadowtype is open source and free: releases live on this repo's own GitHub Releases. There is NO
// Worker, NO Ed25519 manifest signing, and NO license revocation — the GitHub release + notarization
// is the trust anchor. The `latest.json` asset attached to each release carries the manifest below.
//
// The toggle: `shadowtype.autoCheckUpdates` gates the launch + periodic check (AppDelegate);
// `shadowtype.includeBetaBuilds` selects the channel. Manual "Check for Updates…" ignores the toggle.
import Foundation
import CryptoKit
import AppKit

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
    private var stagedAppURL: URL?            // unzipped, verified bundle waiting to be swapped in

    // Production: the public repo's GitHub API base. Tests inject a stub origin/session.
    private init() {
        self.apiBase = UpdateManager.defaultAPIBase
        self.session = .shared
    }

    /// Test seam — inject a stub GitHub-API base + session so the check can be exercised hermetically.
    init(apiBase: URL, session: URLSession = .shared) {
        self.apiBase = apiBase
        self.session = session
    }

    /// The public repo that hosts releases (per the release/update contract).
    static let repoSlug = "dario-valles/shadowtype"
    static let defaultAPIBase = URL(string: "https://api.github.com/repos/\(repoSlug)")!
    /// GitHub's API requires a User-Agent on every request.
    static let userAgent = "Shadowtype-Updater"

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
        state = .checking
        do {
            // nil → nothing published for this channel: we're up to date.
            guard let manifest = try await fetchManifest(channel: channel),
                  manifest.build > UpdateManager.currentBuild() else {
                state = manual ? .upToDate : .idle
                clearPending()
                return nil
            }
            // A newer build exists — but DON'T reveal the menu/"install" affordance yet: it isn't
            // installable until downloadAndStage succeeds (post .shadowtypeUpdateAvailable there).
            pendingManifest = manifest
            state = .available(manifest)
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
        UpdateManager.currentBuild() < manifest.minBuild
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
        let data = try await getData(from: assetURL)
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
            throw UpdateError.badResponse
        }
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
        return releases.first(where: { !$0.draft })
    }

    /// GET with the required User-Agent header (and optional Accept). No auth token (public repo).
    /// 404 (no `releases/latest` published yet) → treated as "nothing published": returns empty Data so
    /// the JSON decode yields nil and the caller reports up-to-date rather than a scary error.
    private func getData(from url: URL, accept: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 404 { return Data() }   // nothing published → up to date
        guard (200...299).contains(http.statusCode) else { throw UpdateError.badResponse }
        return data
    }

    // MARK: - Download + stage

    /// Download the manifest's zip, verify its SHA-256 against the manifest, unzip, strip quarantine,
    /// and codesign-verify the staged bundle. On success → `.readyToInstall`.
    func downloadAndStage(_ manifest: UpdateManifest) async {
        guard let url = URL(string: manifest.url), url.scheme == "https" else {
            state = .failed("Invalid update URL."); clearPending(); return
        }
        state = .downloading(nil)
        do {
            let zipURL = try await download(from: url) { [weak self] p in
                Task { @MainActor in self?.state = .downloading(p) }
            }
            defer { try? FileManager.default.removeItem(at: zipURL) }

            let digest = try Self.sha256Hex(of: zipURL)
            guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
                state = .failed("Update failed integrity check."); clearPending(); return
            }
            let app = try Self.unzipAndVerify(zipURL)
            stagedAppURL = app
            pendingManifest = manifest
            state = .readyToInstall(manifest)
            // Only NOW is the update actually installable — reveal the menu "Install Update vX…" item.
            NotificationCenter.default.post(name: .shadowtypeUpdateAvailable, object: manifest)
        } catch {
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
        let delegate = ProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await session.download(for: req, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.serverError(http.statusCode)
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

    // Unzip with `ditto -x -k`, strip the download quarantine (we already proved authenticity via the
    // manifest's SHA-256), and codesign-verify the bundle before we ever consider swapping it in.
    private static func unzipAndVerify(_ zipURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])

        let apps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw UpdateError.badArchive }

        // Strip com.apple.quarantine so Gatekeeper won't translocate/block the swapped bundle. Safe: the
        // manifest's SHA-256 already authenticated these exact bytes.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // Belt-and-braces: the bundle must still pass codesign --verify (notarized Developer ID build).
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
        return app
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

    /// Swap the staged bundle over the running app and relaunch. We CANNOT overwrite our own running
    /// bundle from inside the process, so we hand the job to a detached shell that waits for this PID to
    /// exit, replaces the bundle, and relaunches — the same dance Sparkle's autoupdate tool performs.
    func installAndRelaunch() {
        guard let staged = stagedAppURL else { state = .failed("No staged update."); return }
        let installPath = Bundle.main.bundlePath
        do {
            let script = try Self.writeRelaunchScript()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Paths are passed as ARGV ($1/$2/$3), never interpolated into the script body — so a space,
            // $, backtick, or quote in the bundle path (e.g. "/Applications/My $Apps/Shadowtype.app")
            // can't break out of quoting or be re-evaluated by the shell.
            p.arguments = [script, String(ProcessInfo.processInfo.processIdentifier), staged.path, installPath]
            try p.run()              // detached; survives our termination
            NSApp.terminate(nil)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    // Static wait-swap-relaunch script in a temp dir (NOT inside the bundle we're about to replace).
    // args: $1 = pid, $2 = staged .app, $3 = install path. Swap is do-no-harm: build a fresh sibling
    // ($dest.new) first, then a same-volume atomic rename; the original stays put until the rename
    // succeeds, and any failure restores it — the user is never left without a launchable app.
    private static func writeRelaunchScript() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-relaunch-\(UUID().uuidString).sh")
        let script = #"""
        #!/bin/sh
        pid="$1"; staged="$2"; dest="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        new="$dest.new"
        rm -rf "$new"
        if ditto "$staged" "$new"; then           # fresh copy → no ditto merge-into-existing hazard
          rm -rf "$dest.old"
          if mv "$dest" "$dest.old"; then          # move original aside (only if we actually can)
            if mv "$new" "$dest"; then             # atomic same-volume rename into place
              rm -rf "$dest.old"
            else
              mv "$dest.old" "$dest" 2>/dev/null   # rollback: restore the original bundle
              rm -rf "$new"
            fi
          else
            rm -rf "$new"                          # couldn't move original — abort, leave it intact
          fi
        fi
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        open "$dest"
        rm -f "$0"
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url.path
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
    }

    private static func message(for error: Error) -> String {
        switch error {
        case UpdateError.badArchive: return "Downloaded update was malformed."
        case UpdateError.signatureMismatch:
            return "Update was signed by a different identity and was not installed."
        case UpdateError.badResponse, UpdateError.serverError: return "Couldn't reach the update server."
        default: return "Update failed. Please try again."
        }
    }
}

// Reused download-progress delegate (a copy of ModelManager.DownloadDelegate — the async download(_:)
// API consumes the temp file itself, so didFinishDownloadingTo is a no-op).
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double?) -> Void
    init(onProgress: @escaping (Double?) -> Void) { self.onProgress = onProgress }

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
}
