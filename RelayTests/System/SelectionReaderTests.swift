import XCTest
@testable import Relay

@MainActor
final class SelectionReaderTests: XCTestCase {
    func testUsesAccessibilityBeforeClipboard() throws {
        let accessibility = FakeAccessibilitySelection(value: "from ax")
        let clipboard = FakeClipboardSelection(value: "from clipboard")
        let reader = SelectionReader(accessibility: accessibility, clipboard: clipboard)

        XCTAssertEqual(try reader.readSelection(), "from ax")
        XCTAssertEqual(clipboard.copySelectionCallCount, 0)
    }

    func testFallsBackToClipboardWhenAccessibilityHasNoSelection() throws {
        let accessibility = FakeAccessibilitySelection(value: nil)
        let clipboard = FakeClipboardSelection(value: "fallback")

        XCTAssertEqual(
            try SelectionReader(accessibility: accessibility, clipboard: clipboard).readSelection(),
            "fallback"
        )
        XCTAssertEqual(clipboard.copySelectionCallCount, 1)
    }

    func testFallsBackToClipboardWhenAccessibilitySelectionIsWhitespace() throws {
        let accessibility = FakeAccessibilitySelection(value: " \n\t ")
        let clipboard = FakeClipboardSelection(value: "fallback")

        XCTAssertEqual(
            try SelectionReader(accessibility: accessibility, clipboard: clipboard).readSelection(),
            "fallback"
        )
    }

    func testThrowsActionableErrorWhenNeitherBackendHasUsableSelection() throws {
        let accessibility = FakeAccessibilitySelection(value: "")
        let clipboard = FakeClipboardSelection(value: "  ")

        XCTAssertThrowsError(
            try SelectionReader(accessibility: accessibility, clipboard: clipboard).readSelection()
        ) { error in
            XCTAssertEqual(error as? SelectionReadingError, .noUsableSelection)
            XCTAssertEqual(
                error.localizedDescription,
                "No selected text found. Select text and try again."
            )
        }
    }

    func testThrowsActionableErrorWhenClipboardFallbackFails() {
        let accessibility = FakeAccessibilitySelection(value: nil)
        let clipboard = FakeClipboardSelection(value: nil, error: TestSelectionError.copyFailed)

        XCTAssertThrowsError(
            try SelectionReader(accessibility: accessibility, clipboard: clipboard).readSelection()
        ) { error in
            XCTAssertEqual(error as? SelectionReadingError, .noUsableSelection)
        }
    }
}

@MainActor
private final class FakeAccessibilitySelection: AccessibilityReading {
    let value: String?

    init(value: String?) {
        self.value = value
    }

    func selectedText() -> String? {
        value
    }
}

@MainActor
private final class FakeClipboardSelection: ClipboardReading {
    let value: String?
    let error: Error?
    private(set) var copySelectionCallCount = 0

    init(value: String?, error: Error? = nil) {
        self.value = value
        self.error = error
    }

    func copyCurrentSelection() throws -> String? {
        copySelectionCallCount += 1
        if let error { throw error }
        return value
    }
}

private enum TestSelectionError: Error {
    case copyFailed
}
