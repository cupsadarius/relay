import AppKit
import CoreGraphics
import Foundation

enum ClipboardRepresentation: Equatable {
    case data(Data)
    case propertyList(Data)
}

struct ClipboardItemSnapshot: Equatable {
    let representations: [String: ClipboardRepresentation]
}

struct ClipboardSnapshot: Equatable {
    let items: [ClipboardItemSnapshot]

    init(items: [ClipboardItemSnapshot]) {
        self.items = items
    }

    init(pasteboardItems: [NSPasteboardItem]) {
        items = pasteboardItems.map { item in
            let representations = item.types.reduce(
                into: [String: ClipboardRepresentation]()
            ) { result, type in
                if let data = item.data(forType: type) {
                    result[type.rawValue] = .data(data)
                } else if let propertyList = item.propertyList(forType: type),
                    PropertyListSerialization.propertyList(propertyList, isValidFor: .binary),
                    let data = try? PropertyListSerialization.data(
                        fromPropertyList: propertyList,
                        format: .binary,
                        options: 0
                    )
                {
                    result[type.rawValue] = .propertyList(data)
                }
            }
            return ClipboardItemSnapshot(representations: representations)
        }
    }
}

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> ClipboardSnapshot
    func string() -> String?
    func write(string: String, ownershipToken: Data) -> Bool
    /// Best-effort conditional restore. NSPasteboard does not offer an atomic compare-and-swap.
    func restore(_ snapshot: ClipboardSnapshot, ifOwnedBy ownershipToken: Data)
    func restore(_ snapshot: ClipboardSnapshot)
}

@MainActor
protocol CopyCommandSending {
    func sendCopy() throws
}

@MainActor
protocol PasteCommandSending {
    func sendPaste() throws
}

@MainActor
protocol ClipboardWaiting {
    /// Suspends (never blocks or pumps a nested run loop) for about `milliseconds`.
    func wait(milliseconds: Int) async
}

/// A cancellation handle for an operation scheduled via `ClipboardRestoreScheduling`.
@MainActor
protocol ClipboardRestoreHandle {
    /// Prevents the scheduled operation from running if it hasn't already. Cancelling an
    /// operation that has already run (or is already cancelled) is a harmless no-op.
    func cancel()
}

/// Schedules a one-shot operation to run later without blocking the calling actor turn
/// (unlike `ClipboardWaiting`, which pumps a nested run loop and would let other handlers
/// reenter while the caller is still on the stack).
@MainActor
protocol ClipboardRestoreScheduling {
    func schedule(
        afterMilliseconds: Int,
        _ operation: @escaping @MainActor () -> Void
    ) -> any ClipboardRestoreHandle
}

/// Serializes `ClipboardService`'s copy cycle against `TextInsertionService`'s paste-fallback
/// write/restore cycle so the two can never interleave on the real pasteboard: one instance is
/// shared between them (see `RelayRuntime.makeProduction()`). `TextInsertionService.insert(_:)`
/// stays synchronous (a deliberate invariant `DictationCoordinator` relies on — see its comment at
/// the `insert` call site), so this gate is asymmetric: the async side (`ClipboardService`) always
/// waits for whichever side already holds the clipboard; the synchronous side (`TextInsertionService`)
/// can only check `isBusy` and decline to start rather than block.
@MainActor
final class ClipboardGate {
    private var releaseTask: Task<Void, Never>?

    /// Whether some operation currently holds the clipboard.
    var isBusy: Bool { releaseTask != nil }

    /// Suspends until whichever operation currently holds the clipboard has released it.
    func acquire() async {
        if let releaseTask {
            await releaseTask.value
        }
    }

    /// Marks the clipboard busy until `task` completes. Synchronous, so a caller that cannot
    /// itself `await` (like a synchronous paste-fallback write) can still register its own busy
    /// window and release it later from wherever its work actually finishes.
    func markBusy(until task: Task<Void, Never>) {
        releaseTask = task
    }

    /// Clears the busy marker. Callers must call this once their own held window ends (whether or
    /// not `task` from `markBusy` has itself finished yet).
    func release() {
        releaseTask = nil
    }
}

@MainActor
final class ClipboardService: ClipboardReading {
    private let pasteboard: any ClipboardPasteboard
    private let copyCommand: any CopyCommandSending
    private let waiter: any ClipboardWaiting
    private let gate: ClipboardGate
    /// The copy currently under way, if any. A second call arriving while one is in flight joins
    /// this instead of starting a second ⌘C (which would snapshot Relay's own temporary content
    /// as the user's "original") or failing outright.
    private var inFlightCopy: Task<String?, Error>?

    init(
        pasteboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        copyCommand: any CopyCommandSending = SystemKeyCommand.copy,
        waiter: any ClipboardWaiting = SleepingClipboardWaiter(),
        gate: ClipboardGate = ClipboardGate()
    ) {
        self.pasteboard = pasteboard
        self.copyCommand = copyCommand
        self.waiter = waiter
        self.gate = gate
    }

    /// Sends ⌘C, waits up to 200 ms for the pasteboard to change, reads the string, then puts the
    /// user's clipboard back — but only if nothing else has written it since the copy landed. A
    /// call landing while one is already in flight (e.g. a quick second Read Selection press)
    /// awaits that same copy and returns its result, rather than failing or re-copying.
    ///
    /// Cancellation only ever affects the calling context that requested it: the underlying copy
    /// (`performCopy`) always runs to completion and restores the clipboard if a copy landed,
    /// regardless of whether this or any other caller stops waiting for it — it's an unstructured
    /// `Task`, immune to any one caller's cancellation. `Task.checkCancellation()` below runs
    /// AFTER that work finishes, against THIS call's own task, so a cancelled caller still gets a
    /// `CancellationError` without ever leaving the clipboard un-restored, and without disturbing
    /// any other caller sharing the same in-flight copy.
    func copyCurrentSelection() async throws -> String? {
        let task: Task<String?, Error>
        let isOwner: Bool
        if let inFlightCopy {
            task = inFlightCopy
            isOwner = false
        } else {
            let newTask = Task { try await self.performCopy() }
            inFlightCopy = newTask
            task = newTask
            isOwner = true
        }
        defer { if isOwner { inFlightCopy = nil } }

        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func performCopy() async throws -> String? {
        // Wait for the gate (e.g. a paste-fallback insertion mid-restore), then hold it for our
        // own duration so a copy in flight is visible to anyone else consulting the gate.
        await gate.acquire()
        let (busySignal, busyContinuation) = AsyncStream<Void>.makeStream()
        gate.markBusy(until: Task { for await _ in busySignal {} })
        defer {
            busyContinuation.finish()
            gate.release()
        }

        let original = pasteboard.snapshot()
        let originalChangeCount = pasteboard.changeCount
        try copyCommand.sendCopy()

        for _ in 0..<10 {
            await waiter.wait(milliseconds: 20)
            let copiedChangeCount = pasteboard.changeCount
            guard copiedChangeCount != originalChangeCount else { continue }
            let copied = pasteboard.string()
            // A later write (the user copying, another app) wins over our restore.
            if pasteboard.changeCount == copiedChangeCount {
                pasteboard.restore(original)
            }
            return copied
        }
        // The copy never landed: the clipboard is still the user's; nothing to restore.
        return nil
    }
}

@MainActor
final class GeneralClipboardPasteboard: ClipboardPasteboard {
    private static let ownershipTokenType = NSPasteboard.PasteboardType("dev.relaymac.Relay.temporary-insertion-token")
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> ClipboardSnapshot {
        ClipboardSnapshot(pasteboardItems: pasteboard.pasteboardItems ?? [])
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func write(string: String, ownershipToken: Data) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string),
            item.setData(ownershipToken, forType: Self.ownershipTokenType)
        else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// NSPasteboard has no atomic conditional write; this minimizes the check-to-restore window.
    func restore(_ snapshot: ClipboardSnapshot, ifOwnedBy ownershipToken: Data) {
        guard contains(ownershipToken: ownershipToken) else { return }
        restore(snapshot)
    }

    private func contains(ownershipToken: Data) -> Bool {
        pasteboard.pasteboardItems?.contains {
            $0.data(forType: Self.ownershipTokenType) == ownershipToken
        } ?? false
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        let items = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for (rawType, representation) in snapshotItem.representations {
                let type = NSPasteboard.PasteboardType(rawType)
                switch representation {
                case let .data(data):
                    item.setData(data, forType: type)
                case let .propertyList(data):
                    guard
                        let propertyList = try? PropertyListSerialization.propertyList(
                            from: data,
                            options: [],
                            format: nil
                        )
                    else { continue }
                    item.setPropertyList(propertyList, forType: type)
                }
            }
            return item
        }

        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}

enum KeyCommandError: Error {
    case eventCreationFailed
}

/// Posts ⌘+`virtualKey` as genuine-looking user input. The combined session source attributes
/// these synthetic events like real keystrokes, so target apps accept them.
@MainActor
struct SystemKeyCommand: CopyCommandSending, PasteCommandSending {
    static let copy = SystemKeyCommand(virtualKey: 8) // kVK_ANSI_C
    static let paste = SystemKeyCommand(virtualKey: 9) // kVK_ANSI_V

    let virtualKey: CGKeyCode

    func sendCopy() throws { try post() }
    func sendPaste() throws { try post() }

    private func post() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else {
            throw KeyCommandError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

@MainActor
struct SleepingClipboardWaiter: ClipboardWaiting {
    /// Always sleeps the full duration. An unstructured `Task` here is not part of the caller's
    /// structured-concurrency cancellation tree, so cancelling `copyCurrentSelection` cannot cut
    /// this sleep short — which would otherwise make the whole 10-iteration wait loop finish
    /// almost instantly, well before the real ⌘C has landed, leaving the clipboard unrestored.
    func wait(milliseconds: Int) async {
        await Task { try? await Task.sleep(for: .milliseconds(milliseconds)) }.value
    }
}

/// Restores the clipboard after a delay without blocking the calling actor turn.
@MainActor
final class TaskClipboardRestoreScheduler: ClipboardRestoreScheduling {
    private struct TaskHandle: ClipboardRestoreHandle {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }

    func schedule(
        afterMilliseconds milliseconds: Int,
        _ operation: @escaping @MainActor () -> Void
    ) -> any ClipboardRestoreHandle {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            operation()
        }
        return TaskHandle(task: task)
    }
}
