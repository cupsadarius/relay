import XCTest

@testable import Relay

@MainActor
final class ProjectSmokeTests: XCTestCase {
    func testAppModelStartsReady() {
        let model = AppModel(runtime: .testing())
        XCTAssertEqual(model.statusText, "Ready")
    }

    /// `RelayRuntime` owns every service's lifetime, so whoever holds the `AppModel` must keep
    /// the runtime alive — `RelayAppDelegate` used to build the runtime inline and drop it.
    func testAppModelRetainsItsRuntime() {
        weak var weakRuntime: RelayRuntime?
        let model: AppModel
        do {
            let runtime = RelayRuntime.testing()
            weakRuntime = runtime
            model = AppModel(runtime: runtime)
        }
        XCTAssertNotNil(weakRuntime, "AppModel must retain its RelayRuntime")
        withExtendedLifetime(model) {}
    }

    /// `DictationCoordinator` writes the shared status line directly — no post-init re-wiring.
    func testRuntimeStatusSinkIsTheModelsStatusText() {
        let runtime = RelayRuntime.testing()
        let model = AppModel(runtime: runtime)

        runtime.status.post("Inserted dictation")

        XCTAssertEqual(model.statusText, "Inserted dictation")
    }
}
