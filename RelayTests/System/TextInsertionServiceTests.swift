import ApplicationServices
import XCTest
@testable import Relay

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testReplacesSelectedTextThroughAccessibilityWhenFocusedElementSupportsIt() throws {
        let accessibility = FakeTextAccessibility(focusedValue: AXUIElementCreateSystemWide(), canReplace: true)
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter()
        )

        try service.insert("dictated text")

        XCTAssertEqual(accessibility.insertedText, ["dictated text"])
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testFallsBackToPasteForUnexpectedFocusedAttributeTypeAndRestoresClipboard() throws {
        let original = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: ["public.utf8-plain-text": .data(Data("original".utf8))])
        ])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let paste = FakePasteCommand()
        let waiter = FakeInsertionWaiter()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: "not an AX element" as CFString, canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: waiter
        )

        try service.insert("dictated text")

        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
        XCTAssertEqual(waiter.waitedMilliseconds, [100])
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }

    func testFallsBackToPasteWhenAccessibilityCannotReplaceSelectedText() throws {
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: AXUIElementCreateSystemWide(), canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter()
        )

        try service.insert("dictated text")

        XCTAssertEqual(paste.sendCount, 1)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
    }

    func testPasteFallbackWritesWaitsThenRestoresClipboardInOrder() throws {
        let events = InsertionEvents()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: FakeInsertionClipboard(events: events),
            pasteCommand: FakePasteCommand(events: events),
            waiter: FakeInsertionWaiter(events: events)
        )

        try service.insert("dictated text")

        XCTAssertEqual(events.values, ["snapshot", "write", "paste", "wait(100)", "restore"])
    }

    func testClipboardWriteFailureRestoresClipboardAndDoesNotPaste() {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original, writeSucceeds: false)
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter()
        )

        XCTAssertThrowsError(try service.insert("dictated text"))
        XCTAssertEqual(paste.sendCount, 0)
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }

    func testRestoresClipboardWhenPasteCommandThrows() {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(error: TestInsertionError.failed),
            waiter: FakeInsertionWaiter()
        )

        XCTAssertThrowsError(try service.insert("dictated text"))
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }
}

@MainActor
private final class FakeTextAccessibility: AccessibilityTextInserting {
    let focusedValue: CFTypeRef?
    let canReplace: Bool
    private(set) var insertedText: [String] = []

    init(focusedValue: CFTypeRef?, canReplace: Bool) {
        self.focusedValue = focusedValue
        self.canReplace = canReplace
    }

    func focusedElementValue() -> CFTypeRef? { focusedValue }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        insertedText.append(text)
        return canReplace
    }
}

@MainActor
private final class FakeInsertionClipboard: ClipboardPasteboard {
    let snapshotValue: ClipboardSnapshot
    let writeSucceeds: Bool
    let events: InsertionEvents?
    private(set) var writtenStrings: [String] = []
    private(set) var restoredSnapshots: [ClipboardSnapshot] = []

    init(
        snapshot: ClipboardSnapshot = .init(items: []),
        writeSucceeds: Bool = true,
        events: InsertionEvents? = nil
    ) {
        self.snapshotValue = snapshot
        self.writeSucceeds = writeSucceeds
        self.events = events
    }

    var changeCount: Int { 0 }
    func snapshot() -> ClipboardSnapshot {
        events?.values.append("snapshot")
        return snapshotValue
    }
    func string() -> String? { nil }
    func write(string: String) -> Bool {
        events?.values.append("write")
        writtenStrings.append(string)
        return writeSucceeds
    }
    func restore(_ snapshot: ClipboardSnapshot) {
        events?.values.append("restore")
        restoredSnapshots.append(snapshot)
    }
}

@MainActor
private final class FakePasteCommand: PasteCommandSending {
    let error: Error?
    let events: InsertionEvents?
    private(set) var sendCount = 0

    init(error: Error? = nil, events: InsertionEvents? = nil) {
        self.error = error
        self.events = events
    }

    func sendPaste() throws {
        events?.values.append("paste")
        sendCount += 1
        if let error { throw error }
    }
}

@MainActor
private final class FakeInsertionWaiter: ClipboardWaiting {
    let events: InsertionEvents?
    private(set) var waitedMilliseconds: [Int] = []
    init(events: InsertionEvents? = nil) { self.events = events }
    func wait(milliseconds: Int) {
        events?.values.append("wait(\(milliseconds))")
        waitedMilliseconds.append(milliseconds)
    }
}

@MainActor
private final class InsertionEvents {
    var values: [String] = []
}

private enum TestInsertionError: Error { case failed }
