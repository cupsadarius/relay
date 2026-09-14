import ApplicationServices
import XCTest
@testable import Relay

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testReplacesSelectedTextThroughAccessibilityWhenFocusedElementSupportsIt() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialValue: "",
            valueAfterReplace: "dictated text"
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .accessibility)
        XCTAssertEqual(accessibility.insertedText, ["dictated text"])
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testAccessibilityWriteReportedSuccessButValueUnchangedFallsBackToPaste() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialValue: "existing text",
            valueAfterReplace: nil
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testSkipsAccessibilityWhenSelectedTextIsNotSettable() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: false,
            initialValue: "existing text",
            valueAfterReplace: "dictated text"
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertTrue(accessibility.insertedText.isEmpty)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testSkipsAccessibilityWhenCurrentValueIsUnreadable() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialValue: nil,
            valueAfterReplace: "dictated text"
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertTrue(accessibility.insertedText.isEmpty)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
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
            waiter: waiter,
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
        XCTAssertEqual(waiter.waitedMilliseconds, [300])
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }

    func testFallsBackToPasteWhenAccessibilityCannotReplaceSelectedText() throws {
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: AXUIElementCreateSystemWide(), canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(paste.sendCount, 1)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
    }

    func testDeniedPostEventPermissionDoesNotMutateClipboardOrPaste() {
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { false }
        )

        XCTAssertThrowsError(try service.insert("dictated text")) {
            XCTAssertEqual($0 as? TextInsertionError, .accessibilityPermissionDenied)
        }
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testPasteFallbackWritesWaitsThenRestoresClipboardInOrder() throws {
        let events = InsertionEvents()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: FakeInsertionClipboard(events: events),
            pasteCommand: FakePasteCommand(events: events),
            waiter: FakeInsertionWaiter(events: events),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(events.values, ["snapshot", "write", "paste", "wait(300)", "restore"])
    }

    func testPasteFallbackWaitsAtLeastThreeHundredMillisecondsBeforeRestoringClipboard() throws {
        let waiter = FakeInsertionWaiter()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: FakeInsertionClipboard(),
            pasteCommand: FakePasteCommand(),
            waiter: waiter,
            canPostEvents: { true }
        )

        _ = try service.insert("dictated text")

        XCTAssertEqual(waiter.waitedMilliseconds.count, 1)
        XCTAssertGreaterThanOrEqual(waiter.waitedMilliseconds[0], 300)
    }

    func testPasteFallbackPreservesClipboardChangedDuringWait() throws {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let waiter = FakeInsertionWaiter(onWait: { clipboard.simulateExternalChange() })
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(),
            waiter: waiter,
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testPasteFallbackPreservesClipboardChangedImmediatelyAfterTemporaryWrite() throws {
        let clipboard = FakeInsertionClipboard()
        clipboard.onWrite = { clipboard.simulateExternalChange() }
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(),
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        _ = try service.insert("dictated text")

        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testClipboardWriteFailureRestoresClipboardAndDoesNotPaste() {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original, writeSucceeds: false)
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        XCTAssertThrowsError(try service.insert("dictated text"))
        XCTAssertEqual(paste.sendCount, 0)
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }

    func testFailedUnownedWritePreservesExternalClipboardUpdate() {
        let clipboard = FakeInsertionClipboard(writeSucceeds: false, retainsOwnershipAfterWrite: false)
        clipboard.onWrite = { clipboard.simulateExternalChange() }
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false), clipboard: clipboard,
            pasteCommand: FakePasteCommand(), waiter: FakeInsertionWaiter(), canPostEvents: { true }
        )

        XCTAssertThrowsError(try service.insert("dictated text"))

        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testConditionalRestoreRefusesWhenOwnershipChangesDuringRestore() throws {
        let clipboard = FakeInsertionClipboard()
        clipboard.onConditionalRestore = { clipboard.simulateExternalChange() }
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false), clipboard: clipboard,
            pasteCommand: FakePasteCommand(), waiter: FakeInsertionWaiter(), canPostEvents: { true }
        )

        _ = try service.insert("dictated text")

        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testRestoresClipboardWhenPasteCommandThrows() {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(error: TestInsertionError.failed),
            waiter: FakeInsertionWaiter(),
            canPostEvents: { true }
        )

        XCTAssertThrowsError(try service.insert("dictated text"))
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }
}

@MainActor
private final class FakeTextAccessibility: AccessibilityTextInserting {
    let focusedValue: CFTypeRef?
    let canReplace: Bool
    let settable: Bool
    let initialValue: String?
    let valueAfterReplace: String?
    private(set) var insertedText: [String] = []
    private var hasReplaced = false

    init(
        focusedValue: CFTypeRef?,
        canReplace: Bool,
        settable: Bool = true,
        initialValue: String? = "",
        valueAfterReplace: String? = nil
    ) {
        self.focusedValue = focusedValue
        self.canReplace = canReplace
        self.settable = settable
        self.initialValue = initialValue
        self.valueAfterReplace = valueAfterReplace
    }

    func focusedElementValue() -> CFTypeRef? { focusedValue }

    func isSelectedTextSettable(_ element: AXUIElement) -> Bool { settable }

    func textValue(of element: AXUIElement) -> String? {
        hasReplaced ? (valueAfterReplace ?? initialValue) : initialValue
    }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        insertedText.append(text)
        hasReplaced = true
        return canReplace
    }
}

@MainActor
private final class FakeInsertionClipboard: ClipboardPasteboard {
    let snapshotValue: ClipboardSnapshot
    let writeSucceeds: Bool
    let retainsOwnershipAfterWrite: Bool
    let events: InsertionEvents?
    private(set) var writtenStrings: [String] = []
    private(set) var restoredSnapshots: [ClipboardSnapshot] = []
    private(set) var externalChangeCount = 0
    private var generation = 0
    private var ownershipToken: Data?
    var onWrite: (() -> Void)?
    var onConditionalRestore: (() -> Void)?

    init(
        snapshot: ClipboardSnapshot = .init(items: []),
        writeSucceeds: Bool = true,
        retainsOwnershipAfterWrite: Bool = true,
        events: InsertionEvents? = nil
    ) {
        self.snapshotValue = snapshot
        self.writeSucceeds = writeSucceeds
        self.retainsOwnershipAfterWrite = retainsOwnershipAfterWrite
        self.events = events
    }

    var changeCount: Int { generation }
    func snapshot() -> ClipboardSnapshot {
        events?.values.append("snapshot")
        return snapshotValue
    }
    func string() -> String? { nil }
    func write(string: String, ownershipToken: Data) -> Bool {
        events?.values.append("write")
        writtenStrings.append(string)
        generation += 1
        self.ownershipToken = retainsOwnershipAfterWrite ? ownershipToken : nil
        onWrite?()
        return writeSucceeds
    }
    func contains(ownershipToken: Data) -> Bool { self.ownershipToken == ownershipToken }
    func restore(_ snapshot: ClipboardSnapshot, ifOwnedBy token: Data) {
        onConditionalRestore?()
        guard contains(ownershipToken: token) else { return }
        restore(snapshot)
    }
    func restore(_ snapshot: ClipboardSnapshot) {
        events?.values.append("restore")
        restoredSnapshots.append(snapshot)
        generation += 1
    }
    func simulateExternalChange() { externalChangeCount += 1; generation += 1; ownershipToken = nil }
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
    let onWait: (() -> Void)?
    private(set) var waitedMilliseconds: [Int] = []
    init(events: InsertionEvents? = nil, onWait: (() -> Void)? = nil) {
        self.events = events
        self.onWait = onWait
    }
    func wait(milliseconds: Int) {
        events?.values.append("wait(\(milliseconds))")
        waitedMilliseconds.append(milliseconds)
        onWait?()
    }
}

@MainActor
private final class InsertionEvents {
    var values: [String] = []
}

private enum TestInsertionError: Error { case failed }
