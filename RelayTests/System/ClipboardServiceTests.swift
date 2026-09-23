import AppKit
import XCTest
@testable import Relay

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testCopiesAfterChangeAndRestoresOriginalClipboard() async throws {
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

        let copied = try await service.copyCurrentSelection()
        XCTAssertEqual(copied, "selected")
        XCTAssertEqual(waiter.waitedMilliseconds, [20])
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }

    func testWaitsAtMostTwoHundredMillisecondsWhenClipboardDoesNotChange() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 2, snapshot: original, copiedString: nil)
        let waiter = FakeClipboardWaiter()
        let service = ClipboardService(
            pasteboard: pasteboard,
            copyCommand: FakeCopyCommand(),
            waiter: waiter
        )

        let copied = try await service.copyCurrentSelection()
        XCTAssertNil(copied)
        XCTAssertEqual(waiter.waitedMilliseconds, Array(repeating: 20, count: 10))
        // Nothing was copied, so the clipboard is still the user's: there is nothing to restore.
        XCTAssertEqual(pasteboard.restoredSnapshots, [])
    }

    func testSendingCopyFailureLeavesTheClipboardUntouched() async {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 2, snapshot: original, copiedString: nil)
        let service = ClipboardService(
            pasteboard: pasteboard,
            copyCommand: FakeCopyCommand(error: TestError.failed),
            waiter: FakeClipboardWaiter()
        )

        do {
            _ = try await service.copyCurrentSelection()
            XCTFail("expected error")
        } catch {}
        XCTAssertEqual(pasteboard.restoredSnapshots, [])
    }

    func testDoesNotRestoreOverContentWrittenAfterTheCopy() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 4, snapshot: original, copiedString: "selected")
        let waiter = FakeClipboardWaiter { pasteboard.changeCount = 5 }
        pasteboard.onString = { pasteboard.changeCount = 6 } // user copies something else meanwhile
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: FakeCopyCommand(), waiter: waiter)

        let copied = try await service.copyCurrentSelection()
        XCTAssertEqual(copied, "selected")
        XCTAssertEqual(pasteboard.restoredSnapshots, [], "newer clipboard content must not be overwritten")
    }

    func testRejectsAReentrantCopyWhileOneIsInFlight() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 1, snapshot: original, copiedString: "selected")
        let gate = WaitGate()
        let waiter = FakeClipboardWaiter(gate: gate) { pasteboard.changeCount = 2 }
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: FakeCopyCommand(), waiter: waiter)

        let first = Task { try await service.copyCurrentSelection() }
        while !gate.isWaiting { await Task.yield() }
        do {
            _ = try await service.copyCurrentSelection()
            XCTFail("reentrant copy must be rejected")
        } catch {
            XCTAssertEqual(error as? ClipboardCopyError, .busy)
        }
        gate.open()

        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "selected")
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
    var onString: () -> Void = {}
    private(set) var restoredSnapshots: [ClipboardSnapshot] = []

    init(changeCount: Int, snapshot: ClipboardSnapshot, copiedString: String?) {
        self.changeCount = changeCount
        self.snapshotValue = snapshot
        self.copiedString = copiedString
    }

    func snapshot() -> ClipboardSnapshot { snapshotValue }
    func string() -> String? { onString(); return copiedString }
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
private final class WaitGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeClipboardWaiter: ClipboardWaiting {
    private let gate: WaitGate?
    private let onWait: () -> Void
    private(set) var waitedMilliseconds: [Int] = []

    init(gate: WaitGate? = nil, onWait: @escaping () -> Void = {}) {
        self.gate = gate
        self.onWait = onWait
    }

    func wait(milliseconds: Int) async {
        waitedMilliseconds.append(milliseconds)
        if let gate, waitedMilliseconds.count == 1 { await gate.wait() }
        onWait()
    }
}

private enum TestError: Error {
    case failed
}
