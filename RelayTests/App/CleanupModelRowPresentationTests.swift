import XCTest

@testable import Relay

final class CleanupModelRowPresentationTests: XCTestCase {
    private func apple(selected: Bool = false, usability: SpeechModelUsability = .usable) -> SpeechModelStatus {
        SpeechModelStatus(
            descriptor: .init(id: CleanupModelID.appleSystem.rawValue, displayName: "Apple Intelligence", detail: "Built in"),
            capabilities: [.select], installState: .downloaded, isSelected: selected, usability: usability
        )
    }

    private func qwen(_ state: SpeechModelInstallState, selected: Bool = false) -> SpeechModelStatus {
        SpeechModelStatus(
            descriptor: .init(id: CleanupModelID.qwen3_0_6b.rawValue, displayName: "Qwen3 0.6B", detail: "~351 MB"),
            capabilities: [.download, .select, .remove], installState: state, isSelected: selected
        )
    }

    func testAvailableAppleRowSaysBuiltInAvailableAndHasNoDownloadOrRemove() {
        let row = CleanupModelRowPresentation.make(status: apple(), testerBusy: false)
        XCTAssertEqual(row.stateLabel, "Built in · Available")
        XCTAssertFalse(row.showsDownload)
        XCTAssertFalse(row.showsRemove)
        XCTAssertTrue(row.base.canSelect)
        XCTAssertTrue(row.canTest)
    }

    func testSelectedAppleRowIsActive() {
        let row = CleanupModelRowPresentation.make(status: apple(selected: true), testerBusy: false)
        XCTAssertEqual(row.stateLabel, "● Active")
        XCTAssertTrue(row.base.isActive)
    }

    func testUnavailableAppleRowShowsTheReasonAndCannotSelectOrTest() {
        let row = CleanupModelRowPresentation.make(status: apple(usability: .unusable(reason: "Apple Intelligence is off")), testerBusy: false)
        XCTAssertEqual(row.stateLabel, "Apple Intelligence is off")
        XCTAssertFalse(row.base.canSelect)
        XCTAssertFalse(row.canTest)
        XCTAssertEqual(row.testHelp, "Apple Intelligence is off")
    }

    func testQwenRowStatesAndTestGating() {
        XCTAssertEqual(CleanupModelRowPresentation.make(status: qwen(.notDownloaded), testerBusy: false).stateLabel, "Not downloaded")
        XCTAssertEqual(CleanupModelRowPresentation.make(status: qwen(.downloading(progress: 0.42)), testerBusy: false).stateLabel, "Downloading 42%")
        XCTAssertEqual(CleanupModelRowPresentation.make(status: qwen(.downloaded, selected: true), testerBusy: false).stateLabel, "● Active")

        let notDownloaded = CleanupModelRowPresentation.make(status: qwen(.notDownloaded), testerBusy: false)
        XCTAssertTrue(notDownloaded.showsDownload)
        XCTAssertFalse(notDownloaded.canTest)
        XCTAssertEqual(notDownloaded.testHelp, "Download the model first.")

        let busy = CleanupModelRowPresentation.make(status: qwen(.downloaded), testerBusy: true)
        XCTAssertFalse(busy.canTest)
        XCTAssertEqual(busy.testHelp, "A test is already running.")
    }
}
