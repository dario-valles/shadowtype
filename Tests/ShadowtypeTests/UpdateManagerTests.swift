// UpdateManager — GitHub-Releases-based in-app auto-updater.
// Hermetic: a URLProtocol stub maps request paths to canned JSON (a GitHub release listing + the
// attached `latest.json` manifest), so check() runs with no network. We also exercise the pure
// build-gating + TCC signature-continuity logic directly.
import XCTest
@testable import Shadowtype

@MainActor
final class UpdateManagerTests: XCTestCase {
    // The injected API base must match the stub's repo path so URLs line up.
    private let apiBase = URL(string: "https://api.github.test/repos/dario-valles/shadowtype")!

    override func setUp() {
        super.setUp()
        StubProtocol.routes = [:]
    }

    override func tearDown() {
        StubProtocol.routes = [:]
        super.tearDown()
    }

    private func sampleManifestJSON(version: String = "0.3.0", build: Int = 99,
                                    minBuild: Int = 0) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": version,
            "build": build,
            "channel": "stable",
            "url": "https://github.test/dl/Shadowtype-\(version)-\(build).zip",
            "sha256": String(repeating: "a", count: 64),
            "minBuild": minBuild,
            "notes": "Faster suggestions.",
        ])
    }

    /// A GitHub release listing JSON whose single release carries a `latest.json` asset.
    private func releaseListingJSON(assetURL: String, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            [
                "prerelease": prerelease,
                "draft": false,
                "assets": [
                    ["name": "latest.json", "browser_download_url": assetURL],
                    ["name": "Shadowtype.dmg", "browser_download_url": "https://github.test/dl/x.dmg"],
                ],
            ]
        ])
    }

    private func singleReleaseJSON(assetURL: String, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "prerelease": prerelease,
            "draft": false,
            "assets": [["name": "latest.json", "browser_download_url": assetURL]],
        ])
    }

    private static func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: - check(): stable channel

    func testCheckStableFindsNewerManifest() async {
        let assetURL = "https://github.test/dl/latest.json"
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dl/latest.json": sampleManifestJSON(build: UpdateManager.currentBuild() + 10),
        ]
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession())
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertEqual(manifest?.version, "0.3.0")
        XCTAssertEqual(manifest?.build, UpdateManager.currentBuild() + 10)
    }

    func testCheckStableTreatsOlderBuildAsUpToDate() async {
        let assetURL = "https://github.test/dl/latest.json"
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            // build 0 is never newer than the running build.
            "/dl/latest.json": sampleManifestJSON(build: 0),
        ]
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession())
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertNil(manifest)
        XCTAssertEqual(mgr.state, .upToDate)
    }

    func testCheckStable404IsUpToDate() async {
        // No `releases/latest` published yet → 404 → treated as up to date (no error).
        StubProtocol.routes = [:]   // every path 404s
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession())
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertNil(manifest)
        XCTAssertEqual(mgr.state, .upToDate)
    }

    // MARK: - check(): beta channel uses the /releases listing

    func testCheckBetaUsesReleasesListing() async {
        let assetURL = "https://github.test/dl/beta-latest.json"
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases": releaseListingJSON(assetURL: assetURL, prerelease: true),
            "/dl/beta-latest.json": sampleManifestJSON(version: "0.4.0",
                                                       build: UpdateManager.currentBuild() + 20),
        ]
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession())
        let manifest = await mgr.check(channel: .beta, manual: true)
        XCTAssertEqual(manifest?.version, "0.4.0")
    }

    // MARK: - Manifest decode (camelCase minBuild)

    func testManifestDecodesMinBuild() async {
        let assetURL = "https://github.test/dl/latest.json"
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dl/latest.json": sampleManifestJSON(build: UpdateManager.currentBuild() + 1, minBuild: 7),
        ]
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession())
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertEqual(manifest?.minBuild, 7)
    }

    // MARK: - Build gating

    func testMandatoryWhenRunningBuildBelowMinBuild() {
        let mgr = UpdateManager(apiBase: apiBase)
        let current = UpdateManager.currentBuild()
        let forced = UpdateManifest(version: "1.0.0", build: current + 5, channel: "stable",
                                    url: "https://x/y.zip", sha256: "a", minBuild: current + 5, notes: "")
        XCTAssertTrue(mgr.isMandatory(forced))
        let optional = UpdateManifest(version: "1.0.0", build: current + 5, channel: "stable",
                                      url: "https://x/y.zip", sha256: "a", minBuild: current, notes: "")
        XCTAssertFalse(mgr.isMandatory(optional))
    }

    // MARK: - Mandatory-pending flag (persisted across launches)

    func testCheckSetsMandatoryPendingForMinBuildForcedUpdate() async {
        let suite = "shadowtype.tests.updatemgr.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let assetURL = "https://github.test/dl/latest.json"
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dl/latest.json": sampleManifestJSON(build: UpdateManager.currentBuild() + 10,
                                                  minBuild: UpdateManager.currentBuild() + 10),
        ]
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession(), defaults: defaults)
        _ = await mgr.check(channel: .stable, manual: true)
        XCTAssertTrue(defaults.bool(forKey: UpdateManager.mandatoryPendingKey))

        // An optional newer build (minBuild already satisfied) clears the flag.
        StubProtocol.routes["/dl/latest.json"] =
            sampleManifestJSON(build: UpdateManager.currentBuild() + 10, minBuild: 0)
        _ = await mgr.check(channel: .stable, manual: true)
        XCTAssertFalse(defaults.bool(forKey: UpdateManager.mandatoryPendingKey))
    }

    func testCheckClearsMandatoryPendingWhenUpToDate() async {
        let suite = "shadowtype.tests.updatemgr.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UpdateManager.mandatoryPendingKey)

        let assetURL = "https://github.test/dl/latest.json"
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dl/latest.json": sampleManifestJSON(build: 0),   // never newer → up to date
        ]
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession(), defaults: defaults)
        _ = await mgr.check(channel: .stable, manual: true)
        XCTAssertFalse(defaults.bool(forKey: UpdateManager.mandatoryPendingKey))
    }

    // MARK: - Failure state carries a human-readable message

    func testFailedDownloadStateCarriesMessage() async {
        let mgr = UpdateManager(apiBase: apiBase, session: Self.stubSession())
        // Non-https URL is rejected before any network I/O.
        let manifest = UpdateManifest(version: "9.9.9", build: UpdateManager.currentBuild() + 1,
                                      channel: "stable", url: "ftp://github.test/x.zip",
                                      sha256: String(repeating: "a", count: 64), minBuild: 0, notes: "")
        await mgr.downloadAndStage(manifest)
        guard case .failed(let message) = mgr.state else {
            return XCTFail("expected .failed, got \(mgr.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - TCC continuity guard (isSignatureContinuous)

    func testSignatureContinuityAllowsSameIdentity() {
        let id = (team: "A9ZQD8SP48", identifier: "com.shadowtype.app")
        XCTAssertTrue(UpdateManager.isSignatureContinuous(running: id, staged: id))
    }

    func testSignatureContinuityBlocksDifferentTeam() {
        XCTAssertFalse(UpdateManager.isSignatureContinuous(
            running: ("A9ZQD8SP48", "com.shadowtype.app"),
            staged: ("ZZZZZZZZZZ", "com.shadowtype.app")))
    }

    func testSignatureContinuityBlocksDifferentIdentifier() {
        XCTAssertFalse(UpdateManager.isSignatureContinuous(
            running: ("A9ZQD8SP48", "com.shadowtype.app"),
            staged: ("A9ZQD8SP48", "com.evil.app")))
    }

    func testSignatureContinuityBlocksUnsignedStaged() {
        // Staged build with no stable Team anchor (self-signed / ad-hoc) would silently drop TCC grants.
        XCTAssertFalse(UpdateManager.isSignatureContinuous(
            running: ("A9ZQD8SP48", "com.shadowtype.app"), staged: nil))
    }

    func testSignatureContinuityPermitsWhenRunningBuildIsDev() {
        // Live app self-signed (no anchored grants to protect) → don't block the DevID upgrade.
        XCTAssertTrue(UpdateManager.isSignatureContinuous(
            running: nil, staged: ("A9ZQD8SP48", "com.shadowtype.app")))
    }
}

// URLProtocol stub: returns the canned body whose key matches the request path; everything else 404s.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = StubProtocol.routes[path]
        let status = body == nil ? 404 : 200
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
