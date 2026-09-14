import ApplicationServices
import XCTest
@testable import Relay

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testReplacesSelectedTextThroughAccessibilityWhenFocusedElementSupportsIt() throws {
        let text = "dictated text"
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialRange: CFRange(location: 5, length: 0),
            rangeAfterReplace: CFRange(location: 5 + text.utf16.count, length: 0)
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert(text)

        XCTAssertEqual(mechanism, .accessibility)
        XCTAssertEqual(accessibility.insertedText, [text])
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testFallsBackToPasteWhenSelectedRangeIsUnreadable() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialRange: nil
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertTrue(accessibility.insertedText.isEmpty, "AX write must never be attempted when the range is unreadable")
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testFallsBackToPasteWhenSelectedRangeIsUnchangedAfterWrite() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialRange: CFRange(location: 5, length: 0),
            rangeAfterReplace: nil
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testFallsBackToPasteWhenSelectedRangeAdvancesByWrongAmount() throws {
        let text = "dictated text"
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialRange: CFRange(location: 5, length: 0),
            rangeAfterReplace: CFRange(location: 5 + text.utf16.count - 1, length: 0)
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert(text)

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, [text])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testSkipsAccessibilityWhenSelectedTextIsNotSettable() throws {
        let text = "dictated text"
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: false,
            initialRange: CFRange(location: 5, length: 0),
            rangeAfterReplace: CFRange(location: 5 + text.utf16.count, length: 0)
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert(text)

        XCTAssertEqual(mechanism, .paste)
        XCTAssertTrue(accessibility.insertedText.isEmpty, "AX write must never be attempted when not settable")
        XCTAssertEqual(clipboard.writtenStrings, [text])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testFallsBackToPasteForUnexpectedFocusedAttributeTypeAndSchedulesClipboardRestore() throws {
        let original = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: ["public.utf8-plain-text": .data(Data("original".utf8))])
        ])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let paste = FakePasteCommand()
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: "not an AX element" as CFString, canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: scheduler,
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [TextInsertionService.pasteClipboardRestoreDelayMilliseconds])
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty, "restore must not happen until the scheduled operation fires")

        scheduler.fireAll()

        XCTAssertEqual(clipboard.restoredSnapshots, [original])
    }

    func testFallsBackToPasteWhenAccessibilityCannotReplaceSelectedText() throws {
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: AXUIElementCreateSystemWide(), canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
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
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { false }
        )

        XCTAssertThrowsError(try service.insert("dictated text")) {
            XCTAssertEqual($0 as? TextInsertionError, .accessibilityPermissionDenied)
        }
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testEmptyTextThrowsWithoutTouchingAccessibilityOrClipboard() {
        let accessibility = FakeTextAccessibility(focusedValue: AXUIElementCreateSystemWide(), canReplace: true)
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        XCTAssertThrowsError(try service.insert("")) {
            XCTAssertEqual($0 as? TextInsertionError, .emptyText)
        }
        XCTAssertTrue(accessibility.insertedText.isEmpty)
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testPasteFallbackWritesAndPastesImmediatelyThenSchedulesRestoreAtTheNamedDelay() throws {
        let events = InsertionEvents()
        let scheduler = FakeClipboardRestoreScheduler(events: events)
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: FakeInsertionClipboard(events: events),
            pasteCommand: FakePasteCommand(events: events),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(
            events.values,
            ["snapshot", "write", "paste", "schedule(\(TextInsertionService.pasteClipboardRestoreDelayMilliseconds))"]
        )

        scheduler.fireAll()

        XCTAssertEqual(
            events.values,
            ["snapshot", "write", "paste", "schedule(\(TextInsertionService.pasteClipboardRestoreDelayMilliseconds))", "restore"]
        )
    }

    func testScheduledRestorePreservesClipboardChangedBeforeItFires() throws {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")
        clipboard.simulateExternalChange()
        scheduler.fireAll()

        XCTAssertEqual(mechanism, .paste)
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testScheduledRestorePreservesClipboardChangedImmediatelyAfterTemporaryWrite() throws {
        let clipboard = FakeInsertionClipboard()
        clipboard.onWrite = { clipboard.simulateExternalChange() }
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        _ = try service.insert("dictated text")
        scheduler.fireAll()

        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testClipboardWriteFailureRestoresClipboardSynchronouslyAndDoesNotPaste() {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original, writeSucceeds: false)
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
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
            pasteCommand: FakePasteCommand(), scheduler: FakeClipboardRestoreScheduler(), canPostEvents: { true }
        )

        XCTAssertThrowsError(try service.insert("dictated text"))

        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testConditionalRestoreRefusesWhenOwnershipChangesDuringRestore() throws {
        let clipboard = FakeInsertionClipboard()
        clipboard.onConditionalRestore = { clipboard.simulateExternalChange() }
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false), clipboard: clipboard,
            pasteCommand: FakePasteCommand(), scheduler: scheduler, canPostEvents: { true }
        )

        _ = try service.insert("dictated text")
        scheduler.fireAll()

        XCTAssertEqual(clipboard.externalChangeCount, 1)
        XCTAssertTrue(clipboard.restoredSnapshots.isEmpty)
    }

    func testRestoresClipboardSynchronouslyWhenPasteCommandThrows() {
        let original = ClipboardSnapshot(items: [])
        let clipboard = FakeInsertionClipboard(snapshot: original)
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(error: TestInsertionError.failed),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        XCTAssertThrowsError(try service.insert("dictated text"))
        XCTAssertEqual(clipboard.restoredSnapshots, [original])
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty, "no restore should be scheduled when paste itself failed")
    }

    func testAcceptsAccessibilityWriteWhenInsertedTextIsLeftSelected() throws {
        let text = "dictated text"
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialRange: CFRange(location: 5, length: 0),
            rangeAfterReplace: CFRange(location: 5, length: text.utf16.count)
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert(text)

        XCTAssertEqual(mechanism, .accessibility)
        XCTAssertTrue(clipboard.writtenStrings.isEmpty)
        XCTAssertEqual(paste.sendCount, 0)
    }

    func testFallsBackToPasteWhenSelectedRangeBecomesUnreadableAfterWrite() throws {
        let accessibility = FakeTextAccessibility(
            focusedValue: AXUIElementCreateSystemWide(),
            canReplace: true,
            settable: true,
            initialRange: CFRange(location: 5, length: 0),
            rangeUnreadableAfterReplace: true
        )
        let clipboard = FakeInsertionClipboard()
        let paste = FakePasteCommand()
        let service = TextInsertionService(
            accessibility: accessibility,
            clipboard: clipboard,
            pasteCommand: paste,
            scheduler: FakeClipboardRestoreScheduler(),
            canPostEvents: { true }
        )

        let mechanism = try service.insert("dictated text")

        XCTAssertEqual(mechanism, .paste)
        XCTAssertFalse(accessibility.insertedText.isEmpty, "the write was attempted; only the post-write read failed")
        XCTAssertEqual(clipboard.writtenStrings, ["dictated text"])
        XCTAssertEqual(paste.sendCount, 1)
    }

    func testOverlappingInsertionsFlushPendingRestoreSoTheUsersOriginalClipboardSurvives() throws {
        let userOriginal = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: ["public.utf8-plain-text": .data(Data("user original".utf8))])
        ])
        let clipboard = FakeInsertionClipboard(snapshot: userOriginal)
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        _ = try service.insert("dictation A")
        _ = try service.insert("dictation B")
        scheduler.fireAll()

        XCTAssertEqual(clipboard.restoredSnapshots.last, userOriginal)
        XCTAssertFalse(
            clipboard.restoredSnapshots.contains { snapshot in
                snapshot.items.contains { item in
                    if case let .data(data) = item.representations["public.utf8-plain-text"] {
                        return data == Data("dictation A".utf8)
                    }
                    return false
                }
            },
            "the user's real clipboard must never be permanently replaced by an earlier dictation's temporary text"
        )
    }

    func testStartingANewPasteInsertionCancelsThePreviousPendingRestore() throws {
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: FakeInsertionClipboard(),
            pasteCommand: FakePasteCommand(),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        _ = try service.insert("dictation A")
        XCTAssertEqual(scheduler.cancelledCount, 0)

        _ = try service.insert("dictation B")
        XCTAssertEqual(scheduler.cancelledCount, 1)
    }

    func testCancelledScheduledRestoreIsANoOpEvenIfItStillFires() throws {
        let userOriginal = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: ["public.utf8-plain-text": .data(Data("user original".utf8))])
        ])
        let clipboard = FakeInsertionClipboard(snapshot: userOriginal)
        let scheduler = FakeClipboardRestoreScheduler()
        let service = TextInsertionService(
            accessibility: FakeTextAccessibility(focusedValue: nil, canReplace: false),
            clipboard: clipboard,
            pasteCommand: FakePasteCommand(),
            scheduler: scheduler,
            canPostEvents: { true }
        )

        _ = try service.insert("dictation A")
        _ = try service.insert("dictation B")
        let restoredCountAfterFlush = clipboard.restoredSnapshots.count

        // Simulate a race where A's Task reached its `operation()` call despite being cancelled.
        scheduler.forceFireCancelledOperations()

        XCTAssertEqual(
            clipboard.restoredSnapshots.count,
            restoredCountAfterFlush,
            "a cancelled restore closure must be a no-op even if it still runs"
        )
    }
}

@MainActor
private final class FakeTextAccessibility: AccessibilityTextInserting {
    let focusedValue: CFTypeRef?
    let canReplace: Bool
    let settable: Bool
    let initialRange: CFRange?
    let rangeAfterReplace: CFRange?
    let rangeUnreadableAfterReplace: Bool
    private(set) var insertedText: [String] = []
    private var hasReplaced = false

    init(
        focusedValue: CFTypeRef?,
        canReplace: Bool,
        settable: Bool = true,
        initialRange: CFRange? = CFRange(location: 0, length: 0),
        rangeAfterReplace: CFRange? = nil,
        rangeUnreadableAfterReplace: Bool = false
    ) {
        self.focusedValue = focusedValue
        self.canReplace = canReplace
        self.settable = settable
        self.initialRange = initialRange
        self.rangeAfterReplace = rangeAfterReplace
        self.rangeUnreadableAfterReplace = rangeUnreadableAfterReplace
    }

    func focusedElementValue() -> CFTypeRef? { focusedValue }

    func isSelectedTextSettable(_ element: AXUIElement) -> Bool { settable }

    func selectedTextRange(of element: AXUIElement) -> CFRange? {
        guard hasReplaced else { return initialRange }
        if rangeUnreadableAfterReplace { return nil }
        return rangeAfterReplace ?? initialRange
    }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        insertedText.append(text)
        hasReplaced = true
        return canReplace
    }
}

@MainActor
private final class FakeInsertionClipboard: ClipboardPasteboard {
    let writeSucceeds: Bool
    let retainsOwnershipAfterWrite: Bool
    let events: InsertionEvents?
    private(set) var writtenStrings: [String] = []
    private(set) var restoredSnapshots: [ClipboardSnapshot] = []
    private(set) var externalChangeCount = 0
    private var generation = 0
    private var ownershipToken: Data?
    /// What `snapshot()` returns right now. Unlike a single fixed value, this tracks writes and
    /// restores so overlapping `insert` calls observe the pasteboard's real, current content —
    /// exactly what makes the overlapping-insertion regression (and its fix) observable in tests.
    private var currentSnapshot: ClipboardSnapshot
    var onWrite: (() -> Void)?
    var onConditionalRestore: (() -> Void)?

    init(
        snapshot: ClipboardSnapshot = .init(items: []),
        writeSucceeds: Bool = true,
        retainsOwnershipAfterWrite: Bool = true,
        events: InsertionEvents? = nil
    ) {
        self.currentSnapshot = snapshot
        self.writeSucceeds = writeSucceeds
        self.retainsOwnershipAfterWrite = retainsOwnershipAfterWrite
        self.events = events
    }

    var changeCount: Int { generation }
    func snapshot() -> ClipboardSnapshot {
        events?.values.append("snapshot")
        return currentSnapshot
    }
    func string() -> String? { nil }
    func write(string: String, ownershipToken: Data) -> Bool {
        events?.values.append("write")
        writtenStrings.append(string)
        generation += 1
        self.ownershipToken = retainsOwnershipAfterWrite ? ownershipToken : nil
        if writeSucceeds {
            currentSnapshot = ClipboardSnapshot(items: [
                ClipboardItemSnapshot(representations: ["public.utf8-plain-text": .data(Data(string.utf8))])
            ])
        }
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
        currentSnapshot = snapshot
        ownershipToken = nil
        generation += 1
    }
    func simulateExternalChange() {
        externalChangeCount += 1
        generation += 1
        ownershipToken = nil
        currentSnapshot = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: ["public.utf8-plain-text": .data(Data("external".utf8))])
        ])
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
private final class FakeClipboardRestoreScheduler: ClipboardRestoreScheduling {
    private final class Handle: ClipboardRestoreHandle {
        private(set) var isCancelled = false
        let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel()
        }
    }

    let events: InsertionEvents?
    private(set) var scheduledDelays: [Int] = []
    private(set) var cancelledCount = 0
    private var handles: [Handle] = []
    private var operations: [() -> Void] = []

    init(events: InsertionEvents? = nil) {
        self.events = events
    }

    func schedule(
        afterMilliseconds milliseconds: Int,
        _ operation: @escaping @MainActor () -> Void
    ) -> any ClipboardRestoreHandle {
        events?.values.append("schedule(\(milliseconds))")
        scheduledDelays.append(milliseconds)
        let handle = Handle(onCancel: { [weak self] in self?.cancelledCount += 1 })
        handles.append(handle)
        operations.append(operation)
        return handle
    }

    /// Mirrors the production `Task`-based scheduler: a cancelled operation never runs.
    func fireAll() {
        let toRun = zip(handles, operations)
        handles.removeAll()
        operations.removeAll()
        for (handle, operation) in toRun where !handle.isCancelled {
            operation()
        }
    }

    /// Test-only escape hatch: fires only the operations whose handles were already cancelled,
    /// simulating a race where a real `Task` reached its `operation()` call despite being
    /// cancelled. Used to prove the closures are safe no-ops in that case, independent of
    /// whether `fireAll()` itself would have skipped them.
    func forceFireCancelledOperations() {
        for (handle, operation) in zip(handles, operations) where handle.isCancelled {
            operation()
        }
    }
}

@MainActor
private final class InsertionEvents {
    var values: [String] = []
}

private enum TestInsertionError: Error { case failed }
