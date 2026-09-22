import CryptoKit
import XCTest
@testable import Shadowtype

final class ModelManagerDownloadIntegrationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shadowtype-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        ModelDownloadStubProtocol.handler = nil
    }

    override func tearDownWithError() throws {
        ModelDownloadStubProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testWrongLinkedSHARejectsStagingWithoutPromotion() async throws {
        let bytes = Data("GGUFwrong-linked-hash".utf8)
        ModelDownloadStubProtocol.handler = { request, client, proto in
            XCTAssertEqual(request.httpMethod, "GET")
            Self.respond(client: client, protocol: proto, request: request, status: 200,
                         headers: [
                            "X-Linked-Etag": String(repeating: "0", count: 64),
                            "X-Linked-Size": "\(bytes.count)",
                         ], body: bytes)
        }
        let destination = tempDirectory.appendingPathComponent("bad.gguf")
        let manager = makeManager()

        do {
            _ = try await manager.downloadAuthenticated(
                from: Self.hfURL("owner/repo/bad.gguf"), to: destination,
                token: nil, expectedSize: Int64(bytes.count)
            )
            XCTFail("expected checksum mismatch")
        } catch let ModelManagerError.checksumMismatch(expected, _) {
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
        } catch {
            XCTFail("expected checksum mismatch, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathExtension("part").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ModelManager.verificationReceiptURL(for: destination).path
        ))
    }

    func testVerificationCompletesBeforeAtomicPromotion() async throws {
        let bytes = Data("GGUFverified-before-promotion".utf8)
        let digest = Self.sha256(bytes)
        ModelDownloadStubProtocol.handler = { request, client, proto in
            Self.respond(client: client, protocol: proto, request: request, status: 200,
                         headers: ["X-Linked-Etag": digest, "X-Linked-Size": "\(bytes.count)"],
                         body: bytes)
        }
        let destination = tempDirectory.appendingPathComponent("ordered.gguf")
        var events: [ModelManager.VerificationEvent] = []
        let manager = makeManager { event in
            events.append(event)
            switch event {
            case .willVerify(let staging, let final), .didVerify(let staging, let final):
                XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            case .didPromote(let final):
                XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
            }
        }

        _ = try await manager.downloadAuthenticated(
            from: Self.hfURL("owner/repo/ordered.gguf"), to: destination,
            token: nil, expectedSize: Int64(bytes.count)
        )

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ModelManager.verificationReceiptURL(for: destination).path
        ))
    }

    func testSameFilenameFromTwoRepositoriesBothImport() async throws {
        let repoA = Self.hfURL("owner-a/repo/model.Q4_K_M.gguf")
        let repoB = Self.hfURL("owner-b/repo/model.Q4_K_M.gguf")
        let bytesA = Data("GGUFrepository-a".utf8)
        let bytesB = Data("GGUFrepository-b".utf8)
        ModelDownloadStubProtocol.handler = { request, client, proto in
            let body = request.url?.path.contains("owner-a") == true ? bytesA : bytesB
            Self.respond(client: client, protocol: proto, request: request, status: 200,
                         headers: [
                            "X-Linked-Etag": Self.sha256(body),
                            "X-Linked-Size": "\(body.count)",
                         ], body: body)
        }
        let store = ImportedModelStore(
            storeURL: tempDirectory.appendingPathComponent("imports.json"),
            importsDir: tempDirectory.appendingPathComponent("imports", isDirectory: true)
        )
        let destinationA = store.huggingFaceDownloadDestination(
            filename: "model.Q4_K_M.gguf", sourceURL: repoA
        )
        let destinationB = store.huggingFaceDownloadDestination(
            filename: "model.Q4_K_M.gguf", sourceURL: repoB
        )
        let manager = makeManager()

        _ = try await manager.downloadAuthenticated(
            from: repoA, to: destinationA, token: nil, expectedSize: Int64(bytesA.count)
        )
        _ = try await manager.downloadAuthenticated(
            from: repoB, to: destinationB, token: nil, expectedSize: Int64(bytesB.count)
        )

        XCTAssertNotEqual(destinationA, destinationB)
        XCTAssertEqual(try Data(contentsOf: destinationA), bytesA)
        XCTAssertEqual(try Data(contentsOf: destinationB), bytesB)
    }

    func testAuthenticatedImportPreflightsBeforeStartingTransfer() async throws {
        let requests = LockedCounter()
        ModelDownloadStubProtocol.handler = { request, client, proto in
            requests.increment()
            XCTFail("network request started before disk preflight: \(request)")
            client.urlProtocol(proto, didFailWithError: URLError(.cancelled))
        }
        let manager = ModelManager(
            sessionConfiguration: Self.configuration(),
            modelsDirectory: tempDirectory,
            availableCapacity: { _ in 4 },
            huggingFaceToken: { nil }
        )

        do {
            _ = try await manager.downloadAuthenticated(
                from: Self.hfURL("owner/repo/large.gguf"),
                to: tempDirectory.appendingPathComponent("large.gguf"),
                token: "secret", expectedSize: 8
            )
            XCTFail("expected insufficient disk space")
        } catch let ModelManagerError.insufficientDiskSpace(neededGB, _) {
            XCTAssertGreaterThan(neededGB, 0)
        } catch {
            XCTFail("expected insufficient disk space, got \(error)")
        }
        XCTAssertEqual(requests.value, 0)
    }

    func testDirectAuthenticatedImportUsesHEADSizeForPreflight() async throws {
        let methods = LockedStrings()
        ModelDownloadStubProtocol.handler = { request, client, proto in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.httpMethod, "HEAD")
            Self.respond(client: client, protocol: proto, request: request, status: 200,
                         headers: ["Content-Length": "64"], body: Data())
        }
        let manager = ModelManager(
            sessionConfiguration: Self.configuration(),
            modelsDirectory: tempDirectory,
            availableCapacity: { _ in 32 },
            huggingFaceToken: { nil }
        )

        do {
            _ = try await manager.downloadAuthenticated(
                from: Self.hfURL("owner/repo/direct.gguf"),
                to: tempDirectory.appendingPathComponent("direct.gguf"),
                token: "secret", expectedSize: nil
            )
            XCTFail("expected HEAD-derived disk preflight failure")
        } catch ModelManagerError.insufficientDiskSpace(_, _) {
            // Expected.
        } catch {
            XCTFail("expected insufficient disk space, got \(error)")
        }
        XCTAssertEqual(methods.values, ["HEAD"])
    }

    func testAuthenticatedInterruptionPersistsTokenFreeRangeStateAndResumes() async throws {
        let full = Data("GGUFabcdefgh".utf8)
        let firstChunk = full.prefix(6)
        let remaining = full.dropFirst(6)
        let digest = Self.sha256(full)
        let source = Self.hfURL("owner/private/secure.gguf?token=url-secret")
        let destination = tempDirectory.appendingPathComponent("secure.gguf")
        let staging = destination.appendingPathExtension("part")
        try Data(firstChunk).write(to: staging)
        let stateURL = ModelManager.authenticatedResumeStateURL(
            for: destination, source: source
        )
        let interruptedState = ModelManager.AuthenticatedResumeState(
            sourceIdentity: ModelManager.resumeSourceIdentity(source),
            offset: Int64(firstChunk.count),
            sha256: digest,
            size: Int64(full.count)
        )
        try JSONEncoder().encode(interruptedState).write(to: stateURL, options: .atomic)
        let stateData = try Data(contentsOf: stateURL)
        let stateText = String(decoding: stateData, as: UTF8.self)
        XCTAssertFalse(stateText.contains("initial-secret"))
        XCTAssertFalse(stateText.contains("url-secret"))
        XCTAssertFalse(stateText.localizedCaseInsensitiveContains("authorization"))

        let requestNumber = LockedCounter()
        ModelDownloadStubProtocol.handler = { request, client, proto in
            let number = requestNumber.increment()
            XCTAssertEqual(number, 1)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer refreshed-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=6-")
            Self.respond(
                client: client, protocol: proto, request: request, status: 206,
                headers: [
                    "Content-Range": "bytes 6-\(full.count - 1)/\(full.count)",
                    "Content-Length": "\(remaining.count)",
                    "X-Linked-Etag": digest,
                    "X-Linked-Size": "\(full.count)",
                ],
                body: Data(remaining)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ModelManager.resumeDataURL(for: destination, source: source).path
        ), "authenticated transfers must never persist opaque URLSession resume blobs")

        let resumedManager = ModelManager(
            sessionConfiguration: Self.configuration(),
            modelsDirectory: tempDirectory,
            availableCapacity: { _ in Int64.max },
            huggingFaceToken: { "refreshed-secret" }
        )
        _ = try await resumedManager.downloadAuthenticated(
            from: source, to: destination, token: "initial-secret",
            expectedSize: Int64(full.count)
        )

        XCTAssertEqual(try Data(contentsOf: destination), full)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        let receipt = try Data(contentsOf: ModelManager.verificationReceiptURL(for: destination))
        XCTAssertFalse(String(decoding: receipt, as: UTF8.self).contains("url-secret"))
        XCTAssertEqual(requestNumber.value, 1)
    }

    func testCuratedReceiptAllowsRelaunchWithoutRehashOrNetwork() async throws {
        let bytes = Data("GGUFreceipt-cache".utf8)
        let digest = Self.sha256(bytes)
        let requests = LockedCounter()
        ModelDownloadStubProtocol.handler = { request, client, proto in
            requests.increment()
            Self.respond(client: client, protocol: proto, request: request, status: 200,
                         headers: ["X-Linked-Size": "\(bytes.count)"], body: bytes)
        }
        let entry = ModelCatalogEntry(
            id: "receipt-test",
            name: "Receipt Test",
            fileName: "receipt.gguf",
            url: Self.hfURL("owner/repo/receipt.gguf"),
            sha256: digest,
            approxRAMGB: 0.1,
            downloadGB: 0.000001,
            paidOnly: false
        )
        let first = makeManager()
        let firstURL = try await first.ensureModel(entry)
        XCTAssertEqual(requests.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ModelManager.verificationReceiptURL(for: firstURL).path
        ))

        ModelDownloadStubProtocol.handler = { request, client, proto in
            XCTFail("a valid receipt must avoid relaunch network access: \(request)")
            client.urlProtocol(proto, didFailWithError: URLError(.cancelled))
        }
        let second = makeManager()
        let secondURL = try await second.ensureModel(entry)
        XCTAssertEqual(secondURL, firstURL)
        XCTAssertEqual(requests.value, 1)
    }

    func testShutdownCancellationWaitsForActiveTransferCancellation() async throws {
        let started = expectation(description: "transfer started")
        ModelDownloadStubProtocol.handler = { request, client, proto in
            started.fulfill()
            // Deliberately remain in flight until the global shutdown hook cancels this task.
        }
        let source = Self.hfURL("owner/private/shutdown.gguf")
        let destination = tempDirectory.appendingPathComponent("shutdown.gguf")
        let manager = ModelManager(
            sessionConfiguration: Self.configuration(),
            modelsDirectory: tempDirectory,
            availableCapacity: { _ in Int64.max },
            huggingFaceToken: { "refreshed-at-resume" }
        )
        let transfer = Task {
            try await manager.downloadAuthenticated(
                from: source, to: destination, token: "initial",
                expectedSize: 64
            )
        }
        await fulfillment(of: [started], timeout: 2)

        XCTAssertTrue(ModelManager.cancelActiveTransfersAndWait(timeout: 2))
        do {
            _ = try await transfer.value
            XCTFail("shutdown cancellation should stop the transfer")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
    }

    // MARK: - Downloaded-file inventory + explicit delete

    /// The grouping rule decides what a single Delete takes with it, so it is pinned directly:
    /// a GGUF owns its sidecars, and nothing else in the directory is ever claimed.
    func testGGUFGroupKeyClaimsSidecarsAndNothingElse() {
        let base = "Qwen3-4B-Base.Q4_K_M.gguf"
        let digest = String(repeating: "a", count: 8)
        for name in [base,
                     base + ".part",
                     base + ".verified.json",
                     "\(base).\(digest).resume",
                     "\(base).\(digest).resume.meta",
                     "\(base).\(digest).range.json"] {
            XCTAssertEqual(ModelManager.ggufGroupKey(for: name), base,
                           "\(name) should belong to \(base)")
        }
        // Not ours: no GGUF anywhere in the name, or a bare extension with no stem.
        for name in ["notes.txt", "imported", ".gguf", ".gguf.part", "model.bin", "README"] {
            XCTAssertNil(ModelManager.ggufGroupKey(for: name), "\(name) must not be claimed")
        }
    }

    /// A retired catalog entry's download is the whole point of the inventory: nothing names it, so
    /// `installed` cannot see it. It has to come back flagged as an orphan, with its sidecars folded
    /// into one deletable group and their bytes counted.
    func testDownloadedModelFilesFlagsRetiredDownloadsAsOrphans() throws {
        let retired = "Qwen3-4B-Base.Q4_K_M.gguf"          // retired in the Qwen 3.5 swap
        let live = ModelCatalog.entries[0].fileName         // still in the catalog
        try write(retired, bytes: 2048)
        try write(retired + ".verified.json", bytes: 16)
        try write("\(retired).abcd1234.resume", bytes: 32)
        try write(live, bytes: 1024)

        let files = makeManager().downloadedModelFiles()

        let orphan = try XCTUnwrap(files.first { $0.id == retired })
        XCTAssertTrue(orphan.isOrphaned)
        XCTAssertFalse(orphan.isPartialOnly)
        XCTAssertEqual(orphan.bytes, 2048 + 16 + 32, "sidecar bytes count toward what is reclaimed")
        XCTAssertEqual(Set(orphan.fileNames),
                       [retired, retired + ".verified.json", "\(retired).abcd1234.resume"])

        let kept = try XCTUnwrap(files.first { $0.id == live })
        XCTAssertFalse(kept.isOrphaned, "a live catalog entry's download is not an orphan")
    }

    /// An abandoned `.part` with no finished GGUF beside it can still be many GB, so it is surfaced
    /// rather than silently ignored — and marked so the row can say what it is.
    func testDownloadedModelFilesSurfacesPartialOnlyDownloads() throws {
        let stem = "Qwen3-30B-A3B-Base.Q4_K_M.gguf"
        try write(stem + ".part", bytes: 4096)

        let file = try XCTUnwrap(makeManager().downloadedModelFiles().first { $0.id == stem })
        XCTAssertTrue(file.isPartialOnly)
        XCTAssertTrue(file.isOrphaned)
        XCTAssertEqual(file.bytes, 4096)
        XCTAssertEqual(file.fileNames, [stem + ".part"], "no GGUF exists, so only the sidecar lists")
    }

    /// BYOM imports are symlinks under `models/imported/` pointing at the user's own files. A
    /// recursive scan would list them and offer to delete them, so the scan must stay shallow.
    func testDownloadedModelFilesIgnoresImportedSymlinksAndForeignFiles() throws {
        let importsDir = tempDirectory.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
        let original = tempDirectory.appendingPathComponent("the-users-own.gguf")
        try Data(repeating: 7, count: 64).write(to: original)
        try FileManager.default.createSymbolicLink(
            at: importsDir.appendingPathComponent("linked.gguf"), withDestinationURL: original)
        try write("notes.txt", bytes: 8)

        let ids = makeManager().downloadedModelFiles().map(\.id)
        XCTAssertFalse(ids.contains("linked.gguf"), "imports/ must never be scanned")
        XCTAssertFalse(ids.contains("notes.txt"), "non-GGUF files are not ours to offer for deletion")
        XCTAssertTrue(ids.contains("the-users-own.gguf"), "a real GGUF at the top level is listed")
    }

    /// Delete takes the GGUF and its sidecars, and stops exactly there — a same-prefix neighbour is
    /// a different model and must survive.
    func testDeleteDownloadedModelFileRemovesTheGroupAndLeavesNeighbours() throws {
        let target = "Qwen3-4B-Base.Q4_K_M.gguf"
        let neighbour = "Qwen3-4B-Base.Q4_K_M-v2.gguf"   // shares a prefix, different model
        try write(target, bytes: 128)
        try write(target + ".part", bytes: 16)
        try write("\(target).abcd1234.resume.meta", bytes: 8)
        try write(neighbour, bytes: 64)

        let removed = makeManager().deleteDownloadedModelFile(id: target)

        XCTAssertEqual(Set(removed),
                       [target, target + ".part", "\(target).abcd1234.resume.meta"])
        XCTAssertFalse(exists(target))
        XCTAssertFalse(exists(target + ".part"))
        XCTAssertTrue(exists(neighbour), "a same-prefix neighbour is a different model")
    }

    /// The id must name a GGUF. A sidecar id would otherwise match every file in its group and
    /// delete a model the caller never named.
    func testDeleteDownloadedModelFileRefusesANonGGUFID() throws {
        let target = "Qwen3-4B-Base.Q4_K_M.gguf"
        try write(target, bytes: 128)
        try write(target + ".part", bytes: 16)

        XCTAssertEqual(makeManager().deleteDownloadedModelFile(id: target + ".part"), [])
        XCTAssertEqual(makeManager().deleteDownloadedModelFile(id: "Qwen3-4B-Base.Q4_K_M"), [])
        XCTAssertEqual(makeManager().deleteDownloadedModelFile(id: ""), [])
        XCTAssertTrue(exists(target), "a refused delete must not touch anything")
        XCTAssertTrue(exists(target + ".part"))
    }

    /// Deleting the file behind the ACTIVE model would leave the engine pointing at nothing and
    /// suggestions dead with no visible cause. The UI does not offer it; the model refuses it too.
    @MainActor
    func testConfirmDeleteRefusesTheActiveModelButAllowsAnyOther() throws {
        let active = ModelCatalog.entries[0]
        let other = ModelCatalog.entries[1]
        try write(active.fileName, bytes: 128)
        try write(other.fileName, bytes: 256)

        let settings = ModelsSettingsModel(manager: makeManager())
        settings.rescan()

        let activeFile = try XCTUnwrap(settings.downloadedFile(for: active))
        settings.confirmDeleteDownload(
            .init(file: activeFile, displayName: active.name, entryID: active.id),
            selectedID: active.id)
        XCTAssertTrue(exists(active.fileName), "the active model's file must survive")

        let otherFile = try XCTUnwrap(settings.downloadedFile(for: other))
        settings.confirmDeleteDownload(
            .init(file: otherFile, displayName: other.name, entryID: other.id),
            selectedID: active.id)
        XCTAssertFalse(exists(other.fileName), "a non-active download deletes normally")
    }

    // MARK: - inventory helpers

    @discardableResult
    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent(name).path)
    }

    private func makeManager(
        onVerificationEvent: ((ModelManager.VerificationEvent) -> Void)? = nil
    ) -> ModelManager {
        ModelManager(
            sessionConfiguration: Self.configuration(),
            modelsDirectory: tempDirectory,
            availableCapacity: { _ in Int64.max },
            huggingFaceToken: { nil },
            onVerificationEvent: onVerificationEvent
        )
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadStubProtocol.self]
        return configuration
    }

    private static func hfURL(_ path: String) -> URL {
        URL(string: "https://huggingface.co/\(path)")!
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func respond(client: URLProtocolClient, protocol proto: URLProtocol,
                                request: URLRequest, status: Int,
                                headers: [String: String], body: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" {
            client.urlProtocol(proto, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(proto)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String] = []

    func append(_ value: String) {
        lock.lock(); strings.append(value); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return strings
    }
}

private final class ModelDownloadStubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, URLProtocolClient, URLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler(request, client!, self)
    }

    override func stopLoading() {}
}
