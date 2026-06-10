// BundleIDValidator — pure shape check behind the Instructions pane's "Add override" field.
// Hermetic: no UI, no UserDefaults.
import XCTest
@testable import Shadowtype

final class BundleIDValidatorTests: XCTestCase {

    func testTypicalBundleIdsAreValid() {
        XCTAssertTrue(BundleIDValidator.isValid("com.apple.mail"))
        XCTAssertTrue(BundleIDValidator.isValid("com.tinyspeck.slackmacgap"))
        XCTAssertTrue(BundleIDValidator.isValid("notion.id"))                  // 2 components is enough
        XCTAssertTrue(BundleIDValidator.isValid("com.apple.dt.Xcode"))         // mixed case OK
        XCTAssertTrue(BundleIDValidator.isValid("org.mozilla.firefox-nightly")) // hyphens OK
        XCTAssertTrue(BundleIDValidator.isValid("com.2do.mac"))                // digit-leading part OK
    }

    func testWhitespaceIsTrimmedBeforeValidation() {
        XCTAssertTrue(BundleIDValidator.isValid("  com.apple.mail \n"))
    }

    func testSingleComponentIsInvalid() {
        XCTAssertFalse(BundleIDValidator.isValid("Slack"))
        XCTAssertFalse(BundleIDValidator.isValid("mail"))
    }

    func testEmptyAndDotEdgeCasesAreInvalid() {
        XCTAssertFalse(BundleIDValidator.isValid(""))
        XCTAssertFalse(BundleIDValidator.isValid("."))
        XCTAssertFalse(BundleIDValidator.isValid("com."))          // empty trailing component
        XCTAssertFalse(BundleIDValidator.isValid(".apple"))        // empty leading component
        XCTAssertFalse(BundleIDValidator.isValid("com..apple"))    // empty middle component
    }

    func testIllegalCharactersAreInvalid() {
        XCTAssertFalse(BundleIDValidator.isValid("com.apple mail"))     // inner space
        XCTAssertFalse(BundleIDValidator.isValid("com.apple.mail!"))    // punctuation
        XCTAssertFalse(BundleIDValidator.isValid("com.apple.mail_app")) // underscore not allowed
        XCTAssertFalse(BundleIDValidator.isValid("com.苹果.mail"))       // non-ASCII rejected
    }
}
