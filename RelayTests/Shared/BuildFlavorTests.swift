import XCTest
@testable import Relay

final class BuildFlavorTests: XCTestCase {
    func testMissingOrUnknownValueIsRelease() {
        XCTAssertEqual(BuildFlavor(infoDictionary: nil), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: [:]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": "beta"]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": 1]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": ""]), .release)
    }

    func testKnownValuesParseCaseAndWhitespaceInsensitively() {
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": "release"]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": "debug"]), .debug)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": " Debug\n"]), .debug)
    }

    func testDerivedNamesAndLegacyOwnership() {
        XCTAssertEqual(BuildFlavor.release.supportDirectoryName, "Relay")
        XCTAssertEqual(BuildFlavor.debug.supportDirectoryName, "Relay Debug")
        XCTAssertEqual(BuildFlavor.debug.displayName, "Relay Debug")
        XCTAssertTrue(BuildFlavor.release.ownsLegacyHookEntries)
        XCTAssertFalse(BuildFlavor.debug.ownsLegacyHookEntries)
    }

    /// The unit tests are hosted in the Debug `Relay.app` (TEST_HOST), so this proves the
    /// `RELAY_BUILD_FLAVOR` build setting reaches the built Info.plist end to end.
    func testTestHostDebugBuildReportsDebugFlavor() {
        XCTAssertEqual(BuildFlavor.current, .debug)
    }
}
