import XCTest
@testable import Shadowtype

final class LocalAPIRoutesSecurityTests: XCTestCase {
    func testCancelledInferenceMapsToExplicitCancellationResponse() {
        let mapped = LocalAPIRoutes.mapError(
            .decodeFailed(InferenceError.cancelled)
        )

        XCTAssertEqual(mapped.0, 499)
        XCTAssertEqual(mapped.1, "Client Closed Request")
        XCTAssertEqual(mapped.2, "generation cancelled")
    }

    func testGeneratedMCPConfigurationUsesProtectedDiscoveryWithoutEmbeddingSecrets() {
        let config = LocalAPISettingsPane.mcpConfiguration(
            bundlePath: "/Applications/Shadowtype.app"
        )

        XCTAssertTrue(config.contains(
            #""command": "/Applications/Shadowtype.app/Contents/Resources/shadowtype-mcp""#
        ))
        XCTAssertFalse(config.contains("SHADOWTYPE_API_PORT"))
        XCTAssertFalse(config.contains("SHADOWTYPE_API_KEY"))
        XCTAssertFalse(config.contains("Bearer"))
    }
}
