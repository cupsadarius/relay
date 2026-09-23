import ApplicationServices

enum TextInsertionError: Error, Equatable {
    case clipboardWriteFailed
    case accessibilityPermissionDenied
    case emptyText
}

/// Which mechanism actually delivered the text. Diagnostics may report this;
/// they must never report the text itself.
enum TextInsertionMechanism: Equatable, Sendable {
    case accessibility
    case paste
}

@MainActor
protocol TextInserting: AnyObject {
    @discardableResult
    func insert(_ text: String) throws -> TextInsertionMechanism
}

@MainActor
protocol AccessibilityTextInserting {
    func focusedElementValue() -> CFTypeRef?
    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool
    /// The element's current selected-text range, read via `kAXSelectedTextRangeAttribute`.
    /// We verify the write against this range rather than the full text value: comparing
    /// whole values risks false positives when unrelated content changes elsewhere in the
    /// document (for example a terminal's scrollback drifting during output), and it requires
    /// copying potentially large document contents on every dictation. `nil` when the
    /// attribute is missing, unreadable, or not a `CFRange`-typed `AXValue`.
    func selectedTextRange(of element: AXUIElement) -> CFRange?
    /// Whether `kAXSelectedTextAttribute` is settable on this element.
    func isSelectedTextSettable(_ element: AXUIElement) -> Bool
}

@MainActor
final class SystemAccessibilityTextInserter: AccessibilityTextInserting {
    func focusedElementValue() -> CFTypeRef? {
        SystemAccessibility.focusedElementValue()
    }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &attributeValue
        ) == .success, let attributeValue else {
            return nil
        }
        guard CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = attributeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    func isSelectedTextSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success else {
            return false
        }
        return settable.boolValue
    }
}

@MainActor
final class TextInsertionService: TextInserting {
    /// How long to wait after posting the paste keystroke before restoring the
    /// original clipboard contents. Must be long enough for the target app to
    /// read the pasteboard before we put the old contents back.
    static let pasteClipboardRestoreDelayMilliseconds = 300

    private let accessibility: any AccessibilityTextInserting
    private let clipboard: any ClipboardPasteboard
    private let pasteCommand: any PasteCommandSending
    private let scheduler: any ClipboardRestoreScheduling
    private let canPostEvents: () -> Bool
    /// The restore for the most recent paste-fallback insertion, if it hasn't run yet.
    private var pendingRestore: (@MainActor () -> Void)?
    private var pendingRestoreHandle: (any ClipboardRestoreHandle)?

    init(
        accessibility: any AccessibilityTextInserting = SystemAccessibilityTextInserter(),
        clipboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        pasteCommand: any PasteCommandSending = SystemKeyCommand.paste,
        scheduler: any ClipboardRestoreScheduling = TaskClipboardRestoreScheduler(),
        canPostEvents: @escaping () -> Bool = { CGPreflightPostEventAccess() }
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.pasteCommand = pasteCommand
        self.scheduler = scheduler
        self.canPostEvents = canPostEvents
    }

    @discardableResult
    func insert(_ text: String) throws -> TextInsertionMechanism {
        guard !text.isEmpty else {
            throw TextInsertionError.emptyText
        }

        if insertViaAccessibility(text) {
            return .accessibility
        }

        guard canPostEvents() else {
            throw TextInsertionError.accessibilityPermissionDenied
        }

        // If an earlier paste's clipboard restore is still pending, run it now instead of
        // letting it fire later: otherwise this insertion would snapshot Relay's own
        // temporary pasteboard content as its "original", and once its own restore fires it
        // would permanently overwrite the user's real clipboard with that leftover text.
        flushPendingRestore()

        let originalClipboard = clipboard.snapshot()
        let ownershipToken = Data(UUID().uuidString.utf8)
        let didWrite = clipboard.write(string: text, ownershipToken: ownershipToken)

        guard didWrite else {
            clipboard.restore(originalClipboard, ifOwnedBy: ownershipToken)
            throw TextInsertionError.clipboardWriteFailed
        }

        do {
            try pasteCommand.sendPaste()
        } catch {
            clipboard.restore(originalClipboard, ifOwnedBy: ownershipToken)
            throw error
        }

        // Restoring synchronously here (via a nested run loop) would let other event
        // handlers reenter while `insert` is still on the stack. Instead we return
        // immediately and let the target app read the pasteboard before restoring it;
        // `flushPendingRestore` above keeps a later overlapping insertion safe.
        let restore: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.clipboard.restore(originalClipboard, ifOwnedBy: ownershipToken)
            self.pendingRestore = nil
            self.pendingRestoreHandle = nil
        }
        pendingRestore = restore
        pendingRestoreHandle = scheduler.schedule(
            afterMilliseconds: Self.pasteClipboardRestoreDelayMilliseconds,
            restore
        )
        return .paste
    }

    /// Cancels and immediately runs any not-yet-fired clipboard restore from a previous paste
    /// insertion. Safe to call when nothing is pending.
    private func flushPendingRestore() {
        pendingRestoreHandle?.cancel()
        pendingRestoreHandle = nil
        let restore = pendingRestore
        pendingRestore = nil
        restore?()
    }

    /// Attempts the Accessibility write and verifies it actually replaced the selection with the
    /// inserted text, by comparing `kAXSelectedTextRangeAttribute` before and after rather than
    /// the full text value: `AXUIElementSetAttributeValue` returning `.success` is not
    /// sufficient evidence on its own, since some apps report success without moving the
    /// selection.
    ///
    /// We accept exactly two post-write shapes, both consistent with "the text was inserted":
    ///  - the caret advanced past the inserted text (`location == original + text.count`, `length == 0`)
    ///  - the inserted text was left selected in place (`location == original`, `length == text.count`)
    /// Any other shape is treated as a failed write and falls back to paste.
    ///
    /// This verification is a heuristic, not a proof, and its two failure directions are not
    /// symmetric: rejecting a write that actually succeeded (a false negative) causes a second,
    /// redundant insertion via the paste fallback — visible, and easy for the user to notice and
    /// undo. Accepting a write that silently did nothing (a false positive that happens to match
    /// one of the shapes above) causes a dropped insertion — silent, and easy to miss. We accept
    /// only these two specific shapes, and nothing looser, to keep that false-positive risk as
    /// small as possible while still covering both mechanisms apps commonly use to reflect an
    /// inserted selection.
    ///
    /// When the element does not report the range as settable and readable, we deliberately skip
    /// AX and use the paste fallback instead, rather than risk a silent no-op or a duplicate paste.
    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focusedElement = SystemAccessibility.element(from: accessibility.focusedElementValue()) else {
            return false
        }

        guard accessibility.isSelectedTextSettable(focusedElement),
              let originalRange = accessibility.selectedTextRange(of: focusedElement) else {
            return false
        }

        guard accessibility.replaceSelectedText(text, in: focusedElement) else {
            return false
        }

        guard let newRange = accessibility.selectedTextRange(of: focusedElement) else {
            return false
        }

        let insertedLength = text.utf16.count
        let caretAdvancedPastInsertion = newRange.location == originalRange.location + insertedLength && newRange.length == 0
        let insertionLeftSelected = newRange.location == originalRange.location && newRange.length == insertedLength
        return caretAdvancedPastInsertion || insertionLeftSelected
    }
}
