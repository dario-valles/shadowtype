// SnippetStore — CRUD, validation, persistence, and corrupt-file tolerance. Hermetic: every test uses
// its own temp file through the injectable storeURL init.
import XCTest
@testable import Shadowtype

final class SnippetStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-snippets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var storeURL: URL { dir.appendingPathComponent("snippets.json") }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("snippets.json.corrupt-") }
    }

    // MARK: - CRUD

    func testStartsEmpty() {
        let store = SnippetStore(storeURL: storeURL)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.isEmpty)
    }

    func testAddNormalizesNameAndKeepsExpansionVerbatim() throws {
        let store = SnippetStore(storeURL: storeURL)
        let added = try store.add(name: "  Sig ", expansion: "Best,\n  Darío ").get()
        XCTAssertEqual(added.name, "sig")
        XCTAssertEqual(added.expansion, "Best,\n  Darío ")
        XCTAssertEqual(store.all(), [added])
        XCTAssertFalse(store.isEmpty)
    }

    func testAllIsSortedByName() {
        let store = SnippetStore(storeURL: storeURL)
        store.add(name: "zeta", expansion: "z")
        store.add(name: "addr", expansion: "a")
        XCTAssertEqual(store.all().map(\.name), ["addr", "zeta"])
    }

    func testAddRejectsInvalidDuplicateAndEmpty() {
        let store = SnippetStore(storeURL: storeURL)
        store.add(name: "sig", expansion: "Best")
        XCTAssertEqual(store.add(name: "my sig", expansion: "x").failure, .invalidName)
        XCTAssertEqual(store.add(name: "", expansion: "x").failure, .invalidName)
        XCTAssertEqual(store.add(name: "SIG", expansion: "x").failure, .duplicateName)
        XCTAssertEqual(store.add(name: "other", expansion: " \n ").failure, .emptyExpansion)
        XCTAssertEqual(store.all().count, 1)
    }

    func testUpdateRenamesAndEdits() throws {
        let store = SnippetStore(storeURL: storeURL)
        let s = try store.add(name: "sig", expansion: "Best").get()
        XCTAssertNil(store.update(id: s.id, name: "Signature", expansion: "Cheers"))
        XCTAssertEqual(store.all(), [Snippet(id: s.id, name: "signature", expansion: "Cheers")])
        // Saving under its own name is not a duplicate.
        XCTAssertNil(store.update(id: s.id, name: "signature", expansion: "Cheers!"))
    }

    func testUpdateRejectsCollisionAndUnknownId() throws {
        let store = SnippetStore(storeURL: storeURL)
        let a = try store.add(name: "a", expansion: "A").get()
        store.add(name: "b", expansion: "B")
        XCTAssertEqual(store.update(id: a.id, name: "B", expansion: "A"), .duplicateName)
        XCTAssertEqual(store.update(id: a.id, name: "a", expansion: ""), .emptyExpansion)
        XCTAssertEqual(store.update(id: UUID(), name: "c", expansion: "C"), .notFound)
        XCTAssertEqual(store.all().first { $0.id == a.id }?.expansion, "A")
    }

    func testValidateExcludingSelf() throws {
        let store = SnippetStore(storeURL: storeURL)
        let s = try store.add(name: "sig", expansion: "x").get()
        XCTAssertEqual(store.validate(name: "sig", expansion: "y"), .duplicateName)
        XCTAssertNil(store.validate(name: "sig", expansion: "y", excluding: s.id))
    }

    func testRemove() throws {
        let store = SnippetStore(storeURL: storeURL)
        let s = try store.add(name: "sig", expansion: "x").get()
        store.remove(id: UUID())          // unknown id: no-op
        XCTAssertEqual(store.all().count, 1)
        store.remove(id: s.id)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: - Persistence

    func testPersistsAcrossInstances() throws {
        let s: Snippet
        do {
            let store = SnippetStore(storeURL: storeURL)
            s = try store.add(name: "sig", expansion: "Best,\nD").get()
            store.add(name: "addr", expansion: "1 Main St")
        }
        let reloaded = SnippetStore(storeURL: storeURL)
        XCTAssertEqual(reloaded.all().map(\.name), ["addr", "sig"])
        XCTAssertEqual(reloaded.all().last, s)
    }

    func testRemovalPersists() throws {
        let store = SnippetStore(storeURL: storeURL)
        let s = try store.add(name: "sig", expansion: "x").get()
        store.remove(id: s.id)
        XCTAssertTrue(SnippetStore(storeURL: storeURL).all().isEmpty)
    }

    // MARK: - Corrupt-file tolerance

    func testGarbageFileLoadsEmptyAndIsBackedUpBeforeOverwrite() throws {
        try Data("{not json".utf8).write(to: storeURL)
        let store = SnippetStore(storeURL: storeURL, now: { Date(timeIntervalSince1970: 1000) })
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(backups().isEmpty, "loading alone must not touch the disk")

        store.add(name: "sig", expansion: "x")
        XCTAssertEqual(backups(), ["snippets.json.corrupt-1000"])
        let backup = try Data(contentsOf: dir.appendingPathComponent("snippets.json.corrupt-1000"))
        XCTAssertEqual(String(decoding: backup, as: UTF8.self), "{not json")
        XCTAssertEqual(SnippetStore(storeURL: storeURL).all().map(\.name), ["sig"])
    }

    func testBadEntriesAreSkippedAndGoodOnesLoad() throws {
        let json = """
        {"version":1,"snippets":[
          {"id":"\(UUID().uuidString)","name":"sig","expansion":"Best"},
          {"name":"noid","expansion":"minted id"},
          {"id":"\(UUID().uuidString)","name":"bad name","expansion":"x"},
          {"id":"\(UUID().uuidString)","name":"SIG","expansion":"duplicate"},
          {"id":"\(UUID().uuidString)","name":"empty","expansion":"  "},
          {"id":42}
        ]}
        """
        try Data(json.utf8).write(to: storeURL)
        let store = SnippetStore(storeURL: storeURL)
        XCTAssertEqual(store.all().map(\.name), ["noid", "sig"])
        XCTAssertEqual(store.all().first { $0.name == "sig" }?.expansion, "Best")

        store.add(name: "new", expansion: "y")
        XCTAssertEqual(backups().count, 1, "dropped entries are preserved in a backup")
    }

    func testCleanFileIsNeverBackedUp() throws {
        do {
            let store = SnippetStore(storeURL: storeURL)
            store.add(name: "sig", expansion: "x")
        }
        let store = SnippetStore(storeURL: storeURL)
        store.add(name: "addr", expansion: "y")
        XCTAssertTrue(backups().isEmpty)
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
