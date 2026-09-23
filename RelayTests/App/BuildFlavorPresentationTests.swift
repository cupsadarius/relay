import SwiftUI
import XCTest

@testable import Relay

final class BuildFlavorPresentationTests: XCTestCase {
    func testReleaseMatchesTodaysMenuBarItem() {
        let presentation = BuildFlavorPresentation(flavor: .release)
        XCTAssertEqual(presentation.menuBarTitle, "Relay")
        XCTAssertEqual(presentation.menuBarSystemImage, "waveform")
        XCTAssertNil(presentation.menuBarBadge)
        XCTAssertNil(presentation.menuHeader)
        XCTAssertNil(presentation.settingsWindowTitle)
        XCTAssertEqual(presentation.quitTitle, "Quit Relay")
    }

    func testDebugIsBadgedAndTitled() {
        let presentation = BuildFlavorPresentation(flavor: .debug)
        XCTAssertEqual(presentation.menuBarTitle, "Relay Debug")
        XCTAssertEqual(presentation.menuBarSystemImage, "waveform")
        XCTAssertEqual(presentation.menuBarBadge, "DEV")
        XCTAssertEqual(presentation.menuHeader, "Relay Debug")
        XCTAssertEqual(presentation.settingsWindowTitle, "Relay Debug Settings")
        XCTAssertEqual(presentation.quitTitle, "Quit Relay Debug")
    }

    @MainActor
    func testMenuBarLabelConstructsForBothFlavors() {
        for flavor in BuildFlavor.allCases {
            _ = MenuBarLabel(presentation: BuildFlavorPresentation(flavor: flavor)).body
        }
    }
}
