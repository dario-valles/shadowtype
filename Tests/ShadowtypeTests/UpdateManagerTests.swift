// UpdateManager — GitHub-Releases-based in-app auto-updater.
// Hermetic: a URLProtocol stub maps request paths to canned JSON (a GitHub release listing + the
// attached `latest.json` manifest), so check() runs with no network. We also exercise the pure
// build-gating + TCC signature-continuity logic directly.
import XCTest
import CryptoKit
@testable import Shadowtype

// Frozen from `git show HEAD:Sources/Shadowtype/UpdateManager.swift` (0.2.5 build 74).
private struct LegacyBuild74Manifest: Decodable, Equatable {
    let version: String
    let build: Int
    let channel: String
    let url: String
    let sha256: String
    let minBuild: Int
    let notes: String
}

@MainActor
final class UpdateManagerTests: XCTestCase {
    // The injected API base must match the stub's repo path so URLs line up.
    private let apiBase = URL(string: "https://api.github.test/repos/dario-valles/shadowtype")!
    private let allowedHosts: Set<String> = [
        "api.github.test", "github.test", "github.com", "release-assets.githubusercontent.com",
    ]
    private let signingKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data((1...32).map(UInt8.init))
    )

    override func setUp() {
        super.setUp()
        StubProtocol.routes = [:]
        StubProtocol.requestCount = 0
    }

    override func tearDown() {
        StubProtocol.routes = [:]
        super.tearDown()
    }

    private func sampleManifestJSON(version: String = "0.3.0", build: Int = 99,
                                    minBuild: Int = 0, channel: String = "stable",
                                    host: String = "github.test") -> Data {
        let payload = sampleManifestPayload(
            version: version, build: build, minBuild: minBuild, channel: channel, host: host
        )
        return dualFormatManifest(payload: payload)
    }

    private func sampleManifestPayload(version: String = "0.3.0", build: Int = 99,
                                       minBuild: Int = 0, channel: String = "stable",
                                       host: String = "github.test") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": version,
            "build": build,
            "channel": channel,
            "url": "https://\(host)/dario-valles/shadowtype/releases/download/v\(version)/Shadowtype-\(version)-\(build).zip",
            "sha256": String(repeating: "a", count: 64),
            "minBuild": minBuild,
            "notes": "Faster suggestions.",
        ], options: [.sortedKeys])
    }

    private func dualFormatManifest(payload: Data, signature: Data? = nil,
                                    flatOverrides: [String: Any] = [:]) -> Data {
        var manifest = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
        manifest.merge(flatOverrides) { _, replacement in replacement }
        manifest["payload"] = payload.base64EncodedString()
        manifest["signature"] = (
            signature ?? (try! signingKey.signature(for: payload))
        ).base64EncodedString()
        return try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private func manager(defaults: UserDefaults = .standard, runningBuild: Int? = nil) -> UpdateManager {
        UpdateManager(
            apiBase: apiBase, session: Self.stubSession(), defaults: defaults,
            manifestPublicKey: signingKey.publicKey.rawRepresentation,
            allowedHosts: allowedHosts, runningBuild: runningBuild
        )
    }

    private func manifestAssetURL(version: String = "0.3.0") -> String {
        "https://github.test/dario-valles/shadowtype/releases/download/v\(version)/latest.json"
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
        let assetURL = manifestAssetURL()
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dario-valles/shadowtype/releases/download/v0.3.0/latest.json":
                sampleManifestJSON(build: UpdateManager.currentBuild() + 10),
        ]
        let mgr = manager()
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertEqual(manifest?.version, "0.3.0")
        XCTAssertEqual(manifest?.build, UpdateManager.currentBuild() + 10)
    }

    func testCheckStableTreatsOlderBuildAsUpToDate() async {
        let assetURL = manifestAssetURL()
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dario-valles/shadowtype/releases/download/v0.3.0/latest.json":
                sampleManifestJSON(build: 50),
        ]
        let mgr = manager(runningBuild: 50)
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertNil(manifest)
        XCTAssertEqual(mgr.state, .upToDate)
    }

    func testCheckStable404IsUpToDate() async {
        // No `releases/latest` published yet → 404 → treated as up to date (no error).
        StubProtocol.routes = [:]   // every path 404s
        let mgr = manager()
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertNil(manifest)
        XCTAssertEqual(mgr.state, .upToDate)
    }

    // MARK: - check(): beta channel uses the /releases listing

    func testCheckBetaUsesReleasesListing() async {
        let assetURL = manifestAssetURL(version: "0.4.0")
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases": releaseListingJSON(assetURL: assetURL, prerelease: true),
            "/dario-valles/shadowtype/releases/download/v0.4.0/latest.json":
                sampleManifestJSON(version: "0.4.0", build: UpdateManager.currentBuild() + 20,
                                   channel: "beta"),
        ]
        let mgr = manager()
        let manifest = await mgr.check(channel: .beta, manual: true)
        XCTAssertEqual(manifest?.version, "0.4.0")
    }

    // MARK: - Manifest decode (camelCase minBuild)

    func testManifestDecodesMinBuild() async {
        let assetURL = manifestAssetURL()
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dario-valles/shadowtype/releases/download/v0.3.0/latest.json":
                sampleManifestJSON(build: UpdateManager.currentBuild() + 20, minBuild: 7),
        ]
        let mgr = manager()
        let manifest = await mgr.check(channel: .stable, manual: true)
        XCTAssertEqual(manifest?.minBuild, 7)
    }

    // MARK: - Build gating

    func testMandatoryWhenRunningBuildBelowMinBuild() {
        let mgr = manager()
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

        let assetURL = manifestAssetURL()
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dario-valles/shadowtype/releases/download/v0.3.0/latest.json":
                sampleManifestJSON(build: UpdateManager.currentBuild() + 10,
                                   minBuild: UpdateManager.currentBuild() + 10),
        ]
        let mgr = manager(defaults: defaults)
        _ = await mgr.check(channel: .stable, manual: true)
        XCTAssertTrue(defaults.bool(forKey: UpdateManager.mandatoryPendingKey))

        // An optional newer build (minBuild already satisfied) clears the flag.
        StubProtocol.routes["/dario-valles/shadowtype/releases/download/v0.3.0/latest.json"] =
            sampleManifestJSON(build: UpdateManager.currentBuild() + 10, minBuild: 0)
        _ = await mgr.check(channel: .stable, manual: true)
        XCTAssertFalse(defaults.bool(forKey: UpdateManager.mandatoryPendingKey))
    }

    func testCheckClearsMandatoryPendingWhenUpToDate() async {
        let suite = "shadowtype.tests.updatemgr.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UpdateManager.mandatoryPendingKey)

        let assetURL = manifestAssetURL()
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dario-valles/shadowtype/releases/download/v0.3.0/latest.json":
                sampleManifestJSON(build: 50),
        ]
        let mgr = manager(defaults: defaults, runningBuild: 50)
        _ = await mgr.check(channel: .stable, manual: true)
        XCTAssertFalse(defaults.bool(forKey: UpdateManager.mandatoryPendingKey))
    }

    // MARK: - Signed manifest authentication

    func testDualFormatManifestDecodesSignedPayload() throws {
        let payload = sampleManifestPayload(build: 99)
        let fixture = dualFormatManifest(payload: payload)
        let expected = try JSONDecoder().decode(UpdateManifest.self, from: payload)
        let actual = try UpdateManager.decodeSignedManifest(
            fixture, publicKey: signingKey.publicKey.rawRepresentation
        )
        XCTAssertEqual(actual, expected)
    }

    func testDualFormatManifestDecodesWithBuild74Schema() throws {
        let payload = sampleManifestPayload(build: 99)
        let fixture = dualFormatManifest(payload: payload)
        let manifest = try JSONDecoder().decode(LegacyBuild74Manifest.self, from: fixture)
        XCTAssertEqual(manifest.build, 99)
        XCTAssertEqual(
            manifest.url,
            "https://github.test/dario-valles/shadowtype/releases/download/v0.3.0/Shadowtype-0.3.0-99.zip"
        )
        XCTAssertEqual(manifest.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(
            manifest,
            try JSONDecoder().decode(LegacyBuild74Manifest.self, from: payload)
        )
    }

    func testUnsignedFlatFieldsDoNotAffectSignedManifestDecode() throws {
        let payload = sampleManifestPayload(build: 99)
        let fixture = dualFormatManifest(payload: payload, flatOverrides: [
            "version": "99.0.0",
            "build": 1,
            "channel": "beta",
            "url": "https://evil.test/tampered.zip",
            "sha256": String(repeating: "b", count: 64),
            "minBuild": 1,
            "notes": "Tampered unsigned notes.",
        ])
        let expected = try JSONDecoder().decode(UpdateManifest.self, from: payload)
        let actual = try UpdateManager.decodeSignedManifest(
            fixture, publicKey: signingKey.publicKey.rawRepresentation
        )
        XCTAssertEqual(actual, expected)
    }

    func testSignedManifestRejectsBadSignature() {
        let payload = sampleManifestPayload(build: 99)
        let envelope = dualFormatManifest(
            payload: payload, signature: Data(repeating: 0, count: 64)
        )
        XCTAssertThrowsError(try UpdateManager.decodeSignedManifest(
            envelope, publicKey: signingKey.publicKey.rawRepresentation
        )) { error in
            guard case UpdateManager.UpdateError.invalidManifestSignature = error else {
                return XCTFail("expected signature rejection, got \(error)")
            }
        }
    }

    func testSignedManifestRejectsTamperedPayload() throws {
        let original = sampleManifestPayload(build: 99)
        let signature = try signingKey.signature(for: original)
        let tampered = sampleManifestPayload(build: 98)
        let envelope = dualFormatManifest(payload: tampered, signature: signature)
        XCTAssertThrowsError(try UpdateManager.decodeSignedManifest(
            envelope, publicKey: signingKey.publicKey.rawRepresentation
        )) { error in
            guard case UpdateManager.UpdateError.invalidManifestSignature = error else {
                return XCTFail("expected tamper rejection, got \(error)")
            }
        }
    }

    func testSignedManifestRejectsWrongPublicKey() {
        let payload = sampleManifestPayload(build: 99)
        let envelope = dualFormatManifest(payload: payload)
        let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try UpdateManager.decodeSignedManifest(
            envelope, publicKey: wrongKey
        )) { error in
            guard case UpdateManager.UpdateError.invalidManifestSignature = error else {
                return XCTFail("expected wrong-key rejection, got \(error)")
            }
        }
    }

    // MARK: - Manifest validation and redirects

    private func validManifest(build: Int = 99, channel: String = "stable",
                               host: String = "github.com",
                               digest: String = String(repeating: "a", count: 64),
                               minBuild: Int = 0) -> UpdateManifest {
        UpdateManifest(
            version: "0.3.0", build: build, channel: channel,
            url: "https://\(host)/dario-valles/shadowtype/releases/download/v0.3.0/Shadowtype-0.3.0-\(build).zip",
            sha256: digest, minBuild: minBuild, notes: ""
        )
    }

    func testManifestValidationAcceptsExpectedArtifact() {
        XCTAssertNoThrow(try UpdateManager.validateManifest(validManifest(), for: .stable))
    }

    func testManifestValidationRejectsHostChannelDigestAndBuildRange() {
        XCTAssertThrowsError(try UpdateManager.validateManifest(
            validManifest(host: "github.com.evil.test"), for: .stable
        ))
        XCTAssertThrowsError(try UpdateManager.validateManifest(
            validManifest(channel: "beta"), for: .stable
        ))
        XCTAssertThrowsError(try UpdateManager.validateManifest(
            validManifest(digest: String(repeating: "A", count: 64)), for: .stable
        ))
        XCTAssertThrowsError(try UpdateManager.validateManifest(
            validManifest(build: 10, minBuild: 11), for: .stable
        ))
    }

    func testManifestValidationRejectsWrongArtifactPath() {
        let manifest = UpdateManifest(
            version: "0.3.0", build: 99, channel: "stable",
            url: "https://github.com/dario-valles/shadowtype/releases/download/v0.3.0/Shadowtype.zip",
            sha256: String(repeating: "a", count: 64), minBuild: 0, notes: ""
        )
        XCTAssertThrowsError(try UpdateManager.validateManifest(manifest, for: .stable))
    }

    func testRedirectValidationAllowsGitHubCDNAndRejectsLookalikeOrHTTP() {
        XCTAssertTrue(UpdateManager.isAllowedRedirectURL(
            URL(string: "https://release-assets.githubusercontent.com/path?token=opaque")!
        ))
        XCTAssertFalse(UpdateManager.isAllowedRedirectURL(
            URL(string: "https://github.com.evil.test/path")!
        ))
        XCTAssertFalse(UpdateManager.isAllowedRedirectURL(
            URL(string: "http://github.com/path")!
        ))
    }

    // MARK: - Build binding and rollback high-water

    func testStagedBuildMustEqualManifestAndExceedBothFloors() {
        XCTAssertFalse(UpdateManager.isBuildEligible(
            manifestBuild: 102, stagedBuild: 101, runningBuild: 100, highWaterBuild: 100
        ))
        XCTAssertTrue(UpdateManager.isBuildEligible(
            manifestBuild: 101, stagedBuild: 101, runningBuild: 100, highWaterBuild: 100
        ))
        XCTAssertFalse(UpdateManager.isBuildEligible(
            manifestBuild: 101, stagedBuild: 101, runningBuild: 100, highWaterBuild: 101
        ))
    }

    func testAppBuildReadsStagedBundleInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-build-test-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Shadowtype.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "321"], format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(UpdateManager.appBuild(at: app), 321)
    }

    func testPersistedHighWaterRejectsRollbackManifest() async {
        let suite = "shadowtype.tests.updatemgr.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(120, forKey: UpdateManager.highWaterBuildKey)
        let assetURL = manifestAssetURL()
        StubProtocol.routes = [
            "/repos/dario-valles/shadowtype/releases/latest": singleReleaseJSON(assetURL: assetURL),
            "/dario-valles/shadowtype/releases/download/v0.3.0/latest.json":
                sampleManifestJSON(build: 110),
        ]
        let mgr = manager(defaults: defaults, runningBuild: 100)
        let result = await mgr.check(channel: .stable, manual: true)
        XCTAssertNil(result)
        XCTAssertEqual(defaults.integer(forKey: UpdateManager.highWaterBuildKey), 120)
    }

    // MARK: - Atomic installer interruption safety

    func testAtomicInstallerInterruptionAlwaysLeavesWorkingDestination() throws {
        let beforeExchange: Set<UpdateManager.InstallFaultPoint> = [
            .candidatePrepared, .candidateVerified, .beforeExchange,
        ]
        for point in UpdateManager.InstallFaultPoint.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("shadowtype-swap-test-\(UUID().uuidString)")
            let destination = root.appendingPathComponent("Shadowtype.app")
            let candidate = root.appendingPathComponent("incoming/Shadowtype.app")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: destination.appendingPathComponent("working.txt"))
            try Data("new".utf8).write(to: candidate.appendingPathComponent("working.txt"))
            defer { try? FileManager.default.removeItem(at: root) }

            _ = try UpdateManager.performAtomicExchange(
                candidate: candidate, destination: destination, faultAt: point,
                verify: { url in
                    XCTAssertTrue(FileManager.default.fileExists(
                        atPath: url.appendingPathComponent("working.txt").path
                    ))
                }
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            let marker = try String(
                contentsOf: destination.appendingPathComponent("working.txt"), encoding: .utf8
            )
            XCTAssertEqual(marker, beforeExchange.contains(point) ? "old" : "new",
                           "fault point: \(point)")
        }
    }

    func testAutomaticCheckHonorsDisabledToggleDespiteMandatoryFlag() async {
        let suite = "shadowtype.tests.updatemgr.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: UpdateManager.autoCheckKey)
        defaults.set(true, forKey: UpdateManager.mandatoryPendingKey)
        let mgr = manager(defaults: defaults, runningBuild: 50)
        await mgr.checkThenStage(channel: .stable, manual: false)
        XCTAssertEqual(StubProtocol.requestCount, 0)
        XCTAssertEqual(mgr.state, .idle)
    }

    // MARK: - Failure state carries a human-readable message

    func testFailedDownloadStateCarriesMessage() async {
        let mgr = manager()
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
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.requestCount += 1
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
