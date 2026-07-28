import Cocoa
import XCTest
@testable import Shadowtype

@MainActor
final class ApplicationMetadataProviderTests: XCTestCase {
    func testInstalledApplicationUsesResolvedDisplayNameAndIcon() {
        let url = URL(fileURLWithPath: "/Applications/Example.app")
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let provider = ApplicationMetadataProvider(
            applicationURL: { $0 == "com.example.app" ? url : nil },
            displayNameAtPath: { _ in "Example" },
            iconForFile: { _ in icon }
        )

        XCTAssertEqual(provider.displayName("com.example.app"), "Example")
        XCTAssertTrue(provider.icon("com.example.app") === icon)
        XCTAssertTrue(provider.isInstalled("com.example.app"))
    }

    func testMissingApplicationFallsBackToLastBundleIdComponent() {
        let provider = ApplicationMetadataProvider(
            applicationURL: { _ in nil },
            displayNameAtPath: { _ in XCTFail("Unexpected display-name lookup"); return "" },
            iconForFile: { _ in XCTFail("Unexpected icon lookup"); return NSImage() }
        )

        XCTAssertEqual(provider.displayName("com.example.Writer"), "Writer")
        XCTAssertEqual(provider.displayName(""), "")
        XCTAssertNil(provider.icon("com.example.Writer"))
        XCTAssertFalse(provider.isInstalled("com.example.Writer"))
    }

    func testMetadataLookupsAreCachedPerBundleId() {
        var applicationLookups = 0
        var displayNameLookups = 0
        var iconLookups = 0
        let provider = ApplicationMetadataProvider(
            applicationURL: { _ in
                applicationLookups += 1
                return URL(fileURLWithPath: "/Applications/Example.app")
            },
            displayNameAtPath: { _ in
                displayNameLookups += 1
                return "Example"
            },
            iconForFile: { _ in
                iconLookups += 1
                return NSImage()
            }
        )

        XCTAssertEqual(provider.displayName("com.example.app"), "Example")
        XCTAssertEqual(provider.displayName("com.example.app"), "Example")
        _ = provider.icon("com.example.app")
        _ = provider.icon("com.example.app")
        XCTAssertTrue(provider.isInstalled("com.example.app"))
        XCTAssertTrue(provider.isInstalled("com.example.app"))

        XCTAssertEqual(applicationLookups, 3)
        XCTAssertEqual(displayNameLookups, 1)
        XCTAssertEqual(iconLookups, 1)
    }
}
