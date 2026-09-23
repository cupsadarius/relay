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

/// A second call landing while one is already in flight (e.g. a quick second Read Selection
    /// press) must join the same copy and see its result, rather than failing with a busy error
    /// or triggering a second ⌘C.
    func testConcurrentCopiesJoinTheSameInFlightCopyRatherThanFailingOrRepeating() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 1, snapshot: original, copiedString: "selected")
        let gate = WaitGate()
        let copyCommand = FakeCopyCommand()
        let waiter = FakeClipboardWaiter(gate: gate) { pasteboard.changeCount = 2 }
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: copyCommand, waiter: waiter)

        let first = Task { try await service.copyCurrentSelection() }
        while !gate.isWaiting { await Task.yield() }
        let second = Task { try await service.copyCurrentSelection() }
        gate.open()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, "selected")
        XCTAssertEqual(secondResult, "selected")
        XCTAssertEqual(copyCommand.callCount, 1, "only one ⌘C must be sent for the pair")
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }

    /// Once an in-flight copy finishes, the NEXT call must start a fresh copy of its own rather
    /// than replaying the finished one's result forever.
    func testANewCopyStartsAfterThePreviousOneFinishes() async throws {
        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 1, snapshot: original, copiedString: "first")
        let copyCommand = FakeCopyCommand()
        let waiter = FakeClipboardWaiter { pasteboard.changeCount += 1 }
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: copyCommand, waiter: waiter)

        let firstResult = try await service.copyCurrentSelection()
        pasteboard.copiedString = "second"
        let secondResult = try await service.copyCurrentSelection()

        XCTAssertEqual(firstResult, "first")
        XCTAssertEqual(secondResult, "second")
        XCTAssertEqual(copyCommand.callCount, 2)
    }

    /// A cancelled caller must not lose the user's original clipboard: the restore that fires
    /// when the copy is detected must still happen before cancellation is honored.
    func testCancellationDuringTheWaitStillRestoresBeforeThrowingCancellationError() async throws {
        let original = ClipboardSnapshot(items: [
            ClipboardItemSnapshot(representations: [
                "public.utf8-plain-text": .data(Data("original".utf8))
            ])
        ])
        let pasteboard = FakeClipboardPasteboard(changeCount: 1, snapshot: original, copiedString: "selected")
        var task: Task<String?, Error>!
        let waiter = FakeClipboardWaiter {
            task.cancel()
            pasteboard.changeCount = 2
        }
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: FakeCopyCommand(), waiter: waiter)

        task = Task { try await service.copyCurrentSelection() }

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertEqual(pasteboard.restoredSnapshots, [original])
    }

    /// `ClipboardService` shares a `ClipboardGate` with `TextInsertionService`'s paste fallback;
    /// while that gate is busy (a paste-fallback write/restore in flight), a copy must wait rather
    /// than read or restore the pasteboard out from under it.
    func testCopyWaitsForTheSharedGateBeforeTouchingThePasteboard() async throws {
        let gate = ClipboardGate()
        let (busySignal, busyContinuation) = AsyncStream<Void>.makeStream()
        gate.markBusy(until: Task { for await _ in busySignal {} })

        let original = ClipboardSnapshot(items: [])
        let pasteboard = FakeClipboardPasteboard(changeCount: 1, snapshot: original, copiedString: "selected")
        let copyCommand = FakeCopyCommand()
        let waiter = FakeClipboardWaiter { pasteboard.changeCount = 2 }
        let service = ClipboardService(pasteboard: pasteboard, copyCommand: copyCommand, waiter: waiter, gate: gate)

        let task = Task { try await service.copyCurrentSelection() }
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(copyCommand.callCount, 0, "must not send ⌘C while the shared gate is busy")

        busyContinuation.finish()
        let result = try await task.value

        XCTAssertEqual(result, "selected")
        XCTAssertEqual(copyCommand.callCount, 1)
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
    var copiedString: String?
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
private final class FakeCopyCommand: CopyCommandSending {
    var error: Error?
    private(set) var callCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func sendCopy() throws {
        callCount += 1
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
