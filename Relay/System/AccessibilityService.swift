import ApplicationServices

@MainActor
protocol AccessibilityElementAccessing {
    func focusedElementValue() -> CFTypeRef?
    func selectedText(from element: AXUIElement) -> String?
}

@MainActor
final class SystemAccessibilityElementAccessor: AccessibilityElementAccessing {
    func focusedElementValue() -> CFTypeRef? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success else { return nil }
        return focusedValue
    }

    func selectedText(from element: AXUIElement) -> String? {
        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )

        guard selectedResult == .success else { return nil }
        return selectedValue as? String
    }
}

@MainActor
final class AccessibilityService: AccessibilityReading {
    private let accessor: any AccessibilityElementAccessing

    init(accessor: any AccessibilityElementAccessing = SystemAccessibilityElementAccessor()) {
        self.accessor = accessor
    }

    func selectedText() -> String? {
        guard let focusedValue = accessor.focusedElementValue(),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        return accessor.selectedText(from: focusedElement)
    }
}
