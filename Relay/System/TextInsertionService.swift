import ApplicationServices

enum TextInsertionError: Error {
    case clipboardWriteFailed
}

@MainActor
protocol AccessibilityTextInserting {
    func focusedElementValue() -> CFTypeRef?
    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool
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
}

@MainActor
final class TextInsertionService {
    private let accessibility: any AccessibilityTextInserting
    private let clipboard: any ClipboardPasteboard
    private let pasteCommand: any PasteCommandSending
    private let waiter: any ClipboardWaiting

    init(
        accessibility: any AccessibilityTextInserting = SystemAccessibilityTextInserter(),
        clipboard: any ClipboardPasteboard = GeneralClipboardPasteboard(),
        pasteCommand: any PasteCommandSending = SystemPasteCommand(),
        waiter: any ClipboardWaiting = RunLoopClipboardWaiter()
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.pasteCommand = pasteCommand
        self.waiter = waiter
    }

    func insert(_ text: String) throws {
        if let focusedValue = accessibility.focusedElementValue(),
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focusedElement = focusedValue as! AXUIElement
            if accessibility.replaceSelectedText(text, in: focusedElement) {
                return
            }
        }

        let originalClipboard = clipboard.snapshot()
        defer { clipboard.restore(originalClipboard) }

        guard clipboard.write(string: text) else {
            throw TextInsertionError.clipboardWriteFailed
        }
        try pasteCommand.sendPaste()
        waiter.wait(milliseconds: 100)
    }
}
