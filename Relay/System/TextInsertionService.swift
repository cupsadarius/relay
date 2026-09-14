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
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success else {
            return nil
        }
        return focusedValue
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

    init(
        accessibility: any AccessibilityTextInserting = SystemAccessibilityTextInserter(),
        clipboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        pasteCommand: any PasteCommandSending = SystemPasteCommand(),
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
        // immediately and let the target app read the pasteboard before restoring it.
        let restoreClipboard = clipboard
        scheduler.schedule(afterMilliseconds: Self.pasteClipboardRestoreDelayMilliseconds) {
            restoreClipboard.restore(originalClipboard, ifOwnedBy: ownershipToken)
        }
        return .paste
    }

    /// Attempts the Accessibility write and verifies it actually moved the selection past the
    /// inserted text, by comparing `kAXSelectedTextRangeAttribute` before and after rather than
    /// the full text value: `AXUIElementSetAttributeValue` returning `.success` is not
    /// sufficient evidence on its own, since some apps report success without moving the
    /// selection. When the element does not report the range as settable and readable, we
    /// deliberately skip AX and use the paste fallback instead, rather than risk a silent
    /// no-op or a duplicate paste.
    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focusedValue = accessibility.focusedElementValue(),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedElement = focusedValue as! AXUIElement

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

        let expectedLocation = originalRange.location + text.utf16.count
        return newRange.location == expectedLocation && newRange.length == 0
    }
}
