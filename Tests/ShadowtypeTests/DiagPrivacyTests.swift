import XCTest
@testable import Shadowtype

final class DiagPrivacyTests: XCTestCase {
    func testSecureFieldKeyDiagnosticDoesNotExtractCharacters() {
        var charactersWereRead = false
        func keyCharacters() -> String {
            charactersWereRead = true
            return "password-do-not-log"
        }

        let message = Diag.keyContentMessage(secureField: true, characters: keyCharacters())

        XCTAssertNil(message)
        XCTAssertFalse(charactersWereRead,
                       "secure-field gate must run before key characters are evaluated")
    }

    func testResetClearsPriorLogWhenDiagnosticsAreDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("diag.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old private diagnostic".utf8).write(to: url)

        Diag.reset(fileURL: url, diagnosticsEnabled: false)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
    }

    func testRedactsEveryAuthorizationHeaderValue() {
        let raw = """
        Authorization: Bearer first-secret
        authorization: Basic second-secret
        Authorization: Custom third-secret
        """

        let redacted = Diag.redactSecrets(raw)

        XCTAssertFalse(redacted.contains("first-secret"))
        XCTAssertFalse(redacted.contains("second-secret"))
        XCTAssertFalse(redacted.contains("third-secret"))
        XCTAssertEqual(redacted.components(separatedBy: "<redacted>").count - 1, 3)
    }
}
