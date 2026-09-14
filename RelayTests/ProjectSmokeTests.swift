import XCTest
@testable import Relay

final class ProjectSmokeTests: XCTestCase {
    func testAppModelStartsReady() async {
        let model = await MainActor.run { AppModel() }
        let status = await MainActor.run { model.statusText }
        XCTAssertEqual(status, "Ready")
    }
}
