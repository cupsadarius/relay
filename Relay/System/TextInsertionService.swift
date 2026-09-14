import ApplicationServices

enum TextInsertionError: Error, Equatable {
    case clipboardWriteFailed
    case accessibilityPermissionDenied
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
    /// The element's current text value, read via `kAXValueAttribute`. `nil` when unreadable.
    func textValue(of element: AXUIElement) -> String?
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

    func textValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
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
    private let waiter: any ClipboardWaiting
    private let canPostEvents: () -> Bool

    init(
        accessibility: any AccessibilityTextInserting = SystemAccessibilityTextInserter(),
        clipboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        pasteCommand: any PasteCommandSending = SystemPasteCommand(),
        waiter: any ClipboardWaiting = RunLoopClipboardWaiter(),
        canPostEvents: @escaping () -> Bool = { CGPreflightPostEventAccess() }
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.pasteCommand = pasteCommand
        self.waiter = waiter
        self.canPostEvents = canPostEvents
    }

    @discardableResult
    func insert(_ text: String) throws -> TextInsertionMechanism {
        if insertViaAccessibility(text) {
            return .accessibility
        }

        guard canPostEvents() else {
            throw TextInsertionError.accessibilityPermissionDenied
        }

        let originalClipboard = clipboard.snapshot()
        let ownershipToken = Data(UUID().uuidString.utf8)
        let didWrite = clipboard.write(string: text, ownershipToken: ownershipToken)
        defer {
            clipboard.restore(originalClipboard, ifOwnedBy: ownershipToken)
        }

        guard didWrite else {
            throw TextInsertionError.clipboardWriteFailed
        }
        try pasteCommand.sendPaste()
        waiter.wait(milliseconds: Self.pasteClipboardRestoreDelayMilliseconds)
        return .paste
    }

    /// Attempts the Accessibility write and verifies it actually changed the
    /// element's text. `AXUIElementSetAttributeValue` returning `.success` is not
    /// sufficient evidence: many apps report success without mutating the
    /// document, or focus is on an element that cannot be safely written to.
    /// When we cannot verify settability or read the current value, we skip AX
    /// entirely rather than risk a silent no-op or a duplicate paste.
    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focusedValue = accessibility.focusedElementValue(),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedElement = focusedValue as! AXUIElement

        guard accessibility.isSelectedTextSettable(focusedElement),
              let originalValue = accessibility.textValue(of: focusedElement) else {
            return false
        }

        guard accessibility.replaceSelectedText(text, in: focusedElement) else {
            return false
        }

        guard let newValue = accessibility.textValue(of: focusedElement) else {
            return false
        }
        return newValue != originalValue && newValue.contains(text)
    }
}
