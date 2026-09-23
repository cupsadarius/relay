import XCTest

@testable import Relay

final class RelayPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let support = "/Users/test/Library/Application Support"

    func testPerBuildSocketAndHelperLiveInSeparateDirectories() {
        XCTAssertEqual(RelayPaths.socketPath(flavor: .release, home: home), "\(support)/Relay/relay.sock")
        XCTAssertEqual(RelayPaths.socketPath(flavor: .debug, home: home), "\(support)/Relay Debug/relay.sock")
        XCTAssertEqual(RelayPaths.stableHelperURL(flavor: .release, home: home).path, "\(support)/Relay/bin/RelayHook")
        XCTAssertEqual(RelayPaths.stableHelperURL(flavor: .debug, home: home).path, "\(support)/Relay Debug/bin/RelayHook")
    }

    func testModelsDirectoryIsSharedByEveryBuild() {
        XCTAssertEqual(RelayPaths.sharedModelsDirectory(home: home).path, "\(support)/Relay/Models")
    }

    func testStableHelperPathRecognition() {
        XCTAssertTrue(RelayPaths.isStableHelperPath("\(support)/Relay/bin/RelayHook"))
        XCTAssertTrue(RelayPaths.isStableHelperPath("\(support)/Relay Debug/bin/RelayHook"))
        XCTAssertFalse(RelayPaths.isStableHelperPath("/Applications/Relay.app/Contents/Helpers/RelayHook"))
        XCTAssertFalse(RelayPaths.isStableHelperPath("\(support)/Other/bin/RelayHook"))
        XCTAssertFalse(RelayPaths.isStableHelperPath("\(support)/Relay/bin/other"))
    }

    func testHelperDerivesItsSocketFromItsOwnLocation() {
        XCTAssertEqual(
            RelayPaths.socketPath(forHelperExecutablePath: "\(support)/Relay Debug/bin/RelayHook", home: home),
            "\(support)/Relay Debug/relay.sock"
        )
        XCTAssertEqual(
            RelayPaths.socketPath(forHelperExecutablePath: "\(support)/Relay/bin/RelayHook", home: home),
            "\(support)/Relay/relay.sock"
        )
    }

    func testHelperOutsideAStableDirectoryFallsBackToReleaseSocket() {
        XCTAssertEqual(
            RelayPaths.socketPath(forHelperExecutablePath: "/Applications/Relay.app/Contents/Helpers/RelayHook", home: home),
            "\(support)/Relay/relay.sock"
        )
    }

    func testAppAndHelperDefaultsAgreeWithRelayPaths() {
        // Test host is the Debug app, so the app listens on the Debug socket...
        XCTAssertEqual(IntegrationServices.productionSocketPath, RelayPaths.socketPath(flavor: .debug))
        XCTAssertNotEqual(IntegrationServices.productionSocketPath, RelayPaths.socketPath(flavor: .release))
        // ...and HookTransportClient's default (computed from the running executable, which here
        // is not a stable helper) falls back to Release.
        XCTAssertEqual(HookTransportClient.defaultSocketPath, RelayPaths.socketPath(flavor: .release))
        XCTAssertEqual(HelperInstaller.stableHelperURL(), RelayPaths.stableHelperURL(flavor: .debug))
    }
}
