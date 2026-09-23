import XCTest
@testable import Relay

final class SpeechModelManagingTests: XCTestCase {
    func testStatusIdMirrorsDescriptorId() {
        let d = SpeechModelDescriptor(id: "small.en", displayName: "small.en", detail: "English only")
        let s = SpeechModelStatus(descriptor: d, capabilities: [.download, .select, .remove], installState: .downloaded, isSelected: true)
        XCTAssertEqual(s.id, "small.en")
    }

    func testInstallStateEquatable() {
        XCTAssertEqual(SpeechModelInstallState.downloading(progress: 0.5), .downloading(progress: 0.5))
        XCTAssertNotEqual(SpeechModelInstallState.downloading(progress: 0.5), .downloaded)
    }
}
