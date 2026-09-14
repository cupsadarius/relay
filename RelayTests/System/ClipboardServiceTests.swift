import AppKit
import XCTest
@testable import Relay

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testCopiesAfterChangeAndRestoresOriginalClipboard() throws {
        let original = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: [
                "public.utf8-plain-text": .data(Data("original".utf8))
            ])
        ])
        let pasteboard = FakeClipboardPasteboard(
            changeCount: 4,
            snapshot: original,
            copiedString: "selected"
        )
        let waiter = FakeClipboardWaiter {
            pasteboard.changeCount = 5
        }
        let service = ClipboardService(
            pasteboard: pasteboard,
            copyCommand: FakeCopyCommand(),
            waiter: waiter
        )

        XCTAssertEqual(try service.copyCurrentSelection(), "selected")
        XCTAssertEqual(waiter.waitedMilliseconds, [20])
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }

    func testWaitsAtMostTwoHundredMillisecondsWhenClipboardDoesNotChange() throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 2, snapshot: original, copiedString: nil)
        let waiter = FakeClipboardWaiter()
        let service = ClipboardService(
            pasteboard: pasteboard,
            copyCommand: FakeCopyCommand(),
            waiter: waiter
        )

        XCTAssertNil(try service.copyCurrentSelection())
        XCTAssertEqual(waiter.waitedMilliseconds, Array(repeating: 20, count: 10))
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }

    func testRestoresClipboardWhenSendingCopyThrows() {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 2, snapshot: original, copiedString: nil)
        let service = ClipboardService(
            pasteboard: pasteboard,
            copyCommand: FakeCopyCommand(error: TestError.failed),
            waiter: FakeClipboardWaiter()
        )

        XCTAssertThrowsError(try service.copyCurrentSelection())
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }

    func testSnapshotCapturesEveryDataRepresentableType() {
        let item = NSPasteboardItem()
        let textType = NSPasteboard.PasteboardType.string
        let customType = NSPasteboard.PasteboardType("dev.relay.binary")
        item.setString("hello", forType: textType)
        item.setData(Data([0x01, 0x02]), forType: customType)

        let snapshot = ClipboardSnapshot(pasteboardItems: [item])

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].representations[textType.rawValue], .data(Data("hello".utf8)))
        XCTAssertEqual(snapshot.items[0].representations[customType.rawValue], .data(Data([0x01, 0x02])))
    }
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboard {
    var changeCount: Int
    let snapshotValue: ClipboardSnapshot
    let copiedString: String?
    private(set) var restoredSnapshots: [ClipboardSnapshot] = []

    init(changeCount: Int, snapshot: ClipboardSnapshot, copiedString: String?) {
        self.changeCount = changeCount
        self.snapshotValue = snapshot
        self.copiedString = copiedString
    }

    func snapshot() -> ClipboardSnapshot { snapshotValue }
    func string() -> String? { copiedString }
    func write(string: String, ownershipToken: Data) -> Bool { true }
    func restore(_ snapshot: ClipboardSnapshot) { restoredSnapshots.append(snapshot) }
    func restore(_ snapshot: ClipboardSnapshot, ifOwnedBy ownershipToken: Data) {}
}

@MainActor
private struct FakeCopyCommand: CopyCommandSending {
    var error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func sendCopy() throws {
        if let error { throw error }
    }
}

@MainActor
private final class FakeClipboardWaiter: ClipboardWaiting {
    private let onWait: () -> Void
    private(set) var waitedMilliseconds: [Int] = []

    init(onWait: @escaping () -> Void = {}) {
        self.onWait = onWait
    }

    func wait(milliseconds: Int) {
        waitedMilliseconds.append(milliseconds)
        onWait()
    }
}

private enum TestError: Error {
    case failed
}
