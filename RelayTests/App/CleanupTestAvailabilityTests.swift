import XCTest

@testable import Relay

final class CleanupTestAvailabilityTests: XCTestCase {
    private func status(_ state: SpeechModelInstallState, usability: SpeechModelUsability = .usable) -> SpeechModelStatus {
        SpeechModelStatus(
            descriptor: .init(id: "m", displayName: "M", detail: nil), capabilities: [.select], installState: state, isSelected: false,
            usability: usability
        )
    }

    func testEnabledWhenDownloadedUsableAndTesterIsFree() {
        let result = CleanupTestAvailability.make(status: status(.downloaded), testerBusy: false)
        XCTAssertTrue(result.enabled)
        XCTAssertNil(result.help)
    }

    func testDisabledWithHelpWhenNotDownloaded() {
        let result = CleanupTestAvailability.make(status: status(.notDownloaded), testerBusy: false)
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.help, "Download the model first.")
    }

    func testDisabledWithHelpWhenATestIsAlreadyRunning() {
        let result = CleanupTestAvailability.make(status: status(.downloaded), testerBusy: true)
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.help, "A test is already running.")
    }

    func testDisabledWithTheUnusableReasonWhenTheModelItselfIsUnusable() {
        let result = CleanupTestAvailability.make(status: status(.downloaded, usability: .unusable(reason: "Apple Intelligence is off")), testerBusy: false)
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.help, "Apple Intelligence is off")
    }

    /// The unusable reason takes priority over "not downloaded" or "busy" when several could apply.
    func testUnusableReasonWinsOverOtherDisabledCases() {
        let result = CleanupTestAvailability.make(status: status(.notDownloaded, usability: .unusable(reason: "Not supported on this Mac")), testerBusy: true)
        XCTAssertEqual(result.help, "Not supported on this Mac")
    }
}
