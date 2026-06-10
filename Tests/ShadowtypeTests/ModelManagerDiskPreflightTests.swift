// ModelManager.checkDiskSpace — pure disk-space preflight comparison + human-facing message.
// Hermetic: synthetic byte counts, no real volume queries.
import XCTest
@testable import Shadowtype

final class ModelManagerDiskPreflightTests: XCTestCase {

    func testEnoughSpaceDoesNotThrow() {
        XCTAssertNoThrow(try ModelManager.checkDiskSpace(neededBytes: 1_000_000_000,
                                                         availableBytes: 2_000_000_000))
    }

    func testExactFitDoesNotThrow() {
        XCTAssertNoThrow(try ModelManager.checkDiskSpace(neededBytes: 5_000_000_000,
                                                         availableBytes: 5_000_000_000))
    }

    func testInsufficientSpaceThrowsWithGBFigures() {
        XCTAssertThrowsError(try ModelManager.checkDiskSpace(neededBytes: 5_000_000_000,
                                                             availableBytes: 1_200_000_000)) { error in
            guard case let ModelManagerError.insufficientDiskSpace(neededGB, availableGB) = error else {
                XCTFail("expected .insufficientDiskSpace, got \(error)"); return
            }
            XCTAssertEqual(neededGB, 5.0, accuracy: 0.01)
            XCTAssertEqual(availableGB, 1.2, accuracy: 0.01)
        }
    }

    func testInsufficientSpaceMessageIsActionable() {
        do {
            try ModelManager.checkDiskSpace(neededBytes: 5_000_000_000, availableBytes: 1_200_000_000)
            XCTFail("expected throw")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertEqual(msg, "Not enough disk space (need 5.0 GB, 1.2 GB available).")
        }
    }

    func testZeroAvailableThrows() {
        XCTAssertThrowsError(try ModelManager.checkDiskSpace(neededBytes: 1, availableBytes: 0))
    }
}
