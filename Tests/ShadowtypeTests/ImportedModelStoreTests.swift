// Pure unit tests for the M3 ImportedModelStore. Each test uses a temp directory so the user's
// real ~/Library/Application Support/Shadowtype/imports.json is never touched.
import XCTest
@testable import Shadowtype

final class ImportedModelStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowtype-imports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> ImportedModelStore {
        ImportedModelStore(
            storeURL: tempDir.appendingPathComponent("imports.json"),
            importsDir: tempDir.appendingPathComponent("imported", isDirectory: true)
        )
    }

    private func makeEntry(id: String = "byom-test-1", linkedPath: String) -> ImportedModelEntry {
        ImportedModelEntry(
            id: id,
            name: "Test Model",
            fileName: "test.gguf",
            linkedPath: linkedPath,
            originalPath: "/Users/test/test.gguf",
            approxRAMGB: 4.0,
            source: .localFile,
            createdAt: Date()
        )
    }

    func testInsertAndRead() {
        let store = makeStore()
        XCTAssertEqual(store.entries().count, 0)
        store.insert(makeEntry(linkedPath: "/tmp/test.gguf"))
        XCTAssertEqual(store.entries().count, 1)
        XCTAssertEqual(store.entries().first?.id, "byom-test-1")
    }

    func testPersistAcrossInstances() {
        let url = tempDir.appendingPathComponent("imports.json")
        let dir = tempDir.appendingPathComponent("imported", isDirectory: true)
        let s1 = ImportedModelStore(storeURL: url, importsDir: dir)
        s1.insert(makeEntry(linkedPath: "/tmp/persist.gguf"))
        XCTAssertEqual(s1.entries().count, 1)

        // Fresh instance reads the same file — entry must round-trip.
        let s2 = ImportedModelStore(storeURL: url, importsDir: dir)
        XCTAssertEqual(s2.entries().count, 1, "fresh store must load prior imports.json")
        XCTAssertEqual(s2.entries().first?.id, "byom-test-1")
    }

    func testDedupByLinkedPath() {
        let store = makeStore()
        store.insert(makeEntry(id: "byom-a", linkedPath: "/tmp/foo.gguf"))
        store.insert(makeEntry(id: "byom-b", linkedPath: "/tmp/foo.gguf"))   // same path → replace
        XCTAssertEqual(store.entries().count, 1)
        XCTAssertEqual(store.entries().first?.id, "byom-b",
                       "re-inserting the same linkedPath must replace, not duplicate")
    }

    func testFindByID() {
        let store = makeStore()
        store.insert(makeEntry(id: "byom-found", linkedPath: "/tmp/x.gguf"))
        XCTAssertNotNil(store.find(id: "byom-found"))
        XCTAssertNil(store.find(id: "byom-missing"))
    }

    func testRemoveDropsEntry() {
        let store = makeStore()
        store.insert(makeEntry(id: "byom-rm", linkedPath: "/tmp/rm.gguf"))
        XCTAssertTrue(store.remove(id: "byom-rm"))
        XCTAssertEqual(store.entries().count, 0)
        XCTAssertFalse(store.remove(id: "byom-rm"),
                       "removing a missing entry must return false, not crash")
    }

    func testGenerateIDIsUnique() {
        let store = makeStore()
        let a = store.generateID()
        let b = store.generateID()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("byom-"))
    }

    func testSymlinkCollisionGetsUniqueSuffix() throws {
        let store = makeStore()
        let importsDir = tempDir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)

        // Create two distinct "source" files with the same basename to force a collision.
        let src1 = tempDir.appendingPathComponent("a/model.gguf")
        let src2 = tempDir.appendingPathComponent("b/model.gguf")
        try FileManager.default.createDirectory(at: src1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x47, 0x47, 0x55, 0x46]).write(to: src1)
        try Data([0x47, 0x47, 0x55, 0x46]).write(to: src2)

        let path1 = try store.createSymlink(from: src1)
        let path2 = try store.createSymlink(from: src2)

        XCTAssertNotEqual(path1, path2,
                          "second symlink with colliding basename must get a unique suffix")
        XCTAssertTrue((path2 as NSString).lastPathComponent.contains("-"),
                      "expected '-2' style suffix on the collided file, got \(path2)")
    }

    func testCatalogEntryAdapterRoundTrip() {
        let entry = makeEntry(linkedPath: "/tmp/cat.gguf")
        let catalog = entry.asCatalogEntry
        XCTAssertEqual(catalog.id, entry.id)
        XCTAssertEqual(catalog.name, entry.name)
        XCTAssertEqual(catalog.url.path, entry.linkedPath)
        XCTAssertNil(catalog.sha256, "imported entries don't carry a sha (we trust local files)")
        XCTAssertEqual(catalog.downloadGB, 0, "no download size; already on disk")
    }

    func testMalformedJSONResetsCleanly() throws {
        let url = tempDir.appendingPathComponent("imports.json")
        try Data("not valid json".utf8).write(to: url)
        let store = ImportedModelStore(storeURL: url,
                                       importsDir: tempDir.appendingPathComponent("imported"))
        XCTAssertEqual(store.entries().count, 0,
                       "a corrupt imports.json must not crash; the store starts empty")
    }
}
