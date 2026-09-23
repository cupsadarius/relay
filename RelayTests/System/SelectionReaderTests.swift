import XCTest
@testable import Relay

@MainActor
final class SelectionReaderTests: XCTestCase {
    func testUsesAccessibilityBeforeClipboard() async throws {
        let accessibility = FakeAccessibilitySelection(value: "from ax")
        let clipboard = FakeClipboardSelection(value: "from clipboard")
        let reader = SelectionReader(accessibility: accessibility, clipboard: clipboard, canReadSelection: { true })

        let result = try await reader.readSelection()
        XCTAssertEqual(result, .init(text: "from ax", source: .accessibility))
        XCTAssertEqual(clipboard.copySelectionCallCount, 0)
    }

    func testFallsBackToClipboardWhenAccessibilityHasNoSelection() async throws {
        let accessibility = FakeAccessibilitySelection(value: nil)
        let clipboard = FakeClipboardSelection(value: "fallback")

        let result = try await SelectionReader(accessibility: accessibility, clipboard: clipboard, canReadSelection: { true }).readSelection()
        XCTAssertEqual(result, .init(text: "fallback", source: .clipboard))
        XCTAssertEqual(clipboard.copySelectionCallCount, 1)
    }

    func testFallsBackToClipboardWhenAccessibilitySelectionIsWhitespace() async throws {
        let accessibility = FakeAccessibilitySelection(value: " \n\t ")
        let clipboard = FakeClipboardSelection(value: "fallback")

        let result = try await SelectionReader(accessibility: accessibility, clipboard: clipboard, canReadSelection: { true }).readSelection()
        XCTAssertEqual(result, .init(text: "fallback", source: .clipboard))
    }

    func testThrowsActionableErrorWhenNeitherBackendHasUsableSelection() async throws {
        let accessibility = FakeAccessibilitySelection(value: "")
        let clipboard = FakeClipboardSelection(value: "  ")

        do {
            _ = try await SelectionReader(accessibility: accessibility, clipboard: clipboard, canReadSelection: { true }).readSelection()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SelectionReadingError, .noUsableSelection)
            XCTAssertEqual(
                error.localizedDescription,
                "No selected text found. Select text and try again."
            )
        }
    }

    func testThrowsActionableErrorWhenClipboardFallbackFails() async {
        let accessibility = FakeAccessibilitySelection(value: nil)
        let clipboard = FakeClipboardSelection(value: nil, error: TestSelectionError.copyFailed)

        do {
            _ = try await SelectionReader(accessibility: accessibility, clipboard: clipboard, canReadSelection: { true }).readSelection()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SelectionReadingError, .noUsableSelection)
        }
    }

    func testReportsMissingPermissionInsteadOfNoSelection() async {
        let reader = SelectionReader(
            accessibility: FakeAccessibilitySelection(value: nil),
            clipboard: FakeClipboardSelection(value: nil),
            canReadSelection: { false }
        )

        do {
            _ = try await reader.readSelection()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SelectionReadingError, .accessibilityPermissionDenied)
            XCTAssertEqual(
                error.localizedDescription,
                "Relay needs Accessibility permission to read selected text. Enable it in System Settings › Privacy & Security › Accessibility."
            )
        }
    }

    func testWithoutPermissionTheClipboardFallbackIsNotAttempted() async {
        let clipboard = FakeClipboardSelection(value: "fallback")
        let reader = SelectionReader(
            accessibility: FakeAccessibilitySelection(value: nil),
            clipboard: clipboard,
            canReadSelection: { false }
        )

        _ = try? await reader.readSelection()

        XCTAssertEqual(clipboard.copySelectionCallCount, 0)
    }

    /// A cancelled clipboard copy must surface as a `CancellationError`, not get mapped to the
    /// generic "no selection" error like every other clipboard failure.
    func testRethrowsCancellationRatherThanMappingToNoSelection() async {
        let reader = SelectionReader(
            accessibility: FakeAccessibilitySelection(value: nil),
            clipboard: FakeClipboardSelection(value: nil, error: CancellationError()),
            canReadSelection: { true }
        )

        do {
            _ = try await reader.readSelection()
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
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

    func copyCurrentSelection() async throws -> String? {
        copySelectionCallCount += 1
        if let error { throw error }
        return value
    }
}

private enum TestSelectionError: Error {
    case copyFailed
}
