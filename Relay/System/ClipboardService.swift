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
                          ) {
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
    func wait(milliseconds: Int)
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

@MainActor
final class ClipboardService: ClipboardReading {
    private let pasteboard: any ClipboardPasteboard
    private let copyCommand: any CopyCommandSending
    private let waiter: any ClipboardWaiting

    init(
        pasteboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        copyCommand: any CopyCommandSending = SystemCopyCommand(),
        waiter: any ClipboardWaiting = RunLoopClipboardWaiter()
    ) {
        self.pasteboard = pasteboard
        self.copyCommand = copyCommand
        self.waiter = waiter
    }

    func copyCurrentSelection() throws -> String? {
        let original = pasteboard.snapshot()
        defer { pasteboard.restore(original) }

        let originalChangeCount = pasteboard.changeCount
        try copyCommand.sendCopy()

        for _ in 0..<10 {
            waiter.wait(milliseconds: 20)
            if pasteboard.changeCount != originalChangeCount {
                return pasteboard.string()
            }
        }

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
                    guard let propertyList = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                    ) else { continue }
                    item.setPropertyList(propertyList, forType: type)
                }
            }
            return item
        }

        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}

enum CopyCommandError: Error {
    case eventCreationFailed
}

@MainActor
struct SystemCopyCommand: CopyCommandSending {
    func sendCopy() throws {
        // The combined session source attributes these synthetic events like genuine user
        // input, so target apps accept them instead of ignoring or mishandling them.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            throw CopyCommandError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

@MainActor
struct SystemPasteCommand: PasteCommandSending {
    func sendPaste() throws {
        // The combined session source attributes these synthetic events like genuine user
        // input, so target apps accept them instead of ignoring or mishandling them.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw CopyCommandError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

@MainActor
struct RunLoopClipboardWaiter: ClipboardWaiting {
    func wait(milliseconds: Int) {
        RunLoop.current.run(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
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
