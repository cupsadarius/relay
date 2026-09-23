import ApplicationServices

/// The one place Relay reads the system-wide focused UI element.
@MainActor
enum SystemAccessibility {
    static func focusedElementValue() -> CFTypeRef? {
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(),
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            ) == .success
        else { return nil }
        return focusedValue
    }

    /// Narrows an AX attribute value to an element, or `nil` if it is some other CF type.
    static func element(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

@MainActor
protocol AccessibilityElementAccessing {
    func focusedElementValue() -> CFTypeRef?
    func selectedText(from element: AXUIElement) -> String?
}

@MainActor
final class SystemAccessibilityElementAccessor: AccessibilityElementAccessing {
    func focusedElementValue() -> CFTypeRef? {
        SystemAccessibility.focusedElementValue()
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
        guard let element = SystemAccessibility.element(from: accessor.focusedElementValue()) else { return nil }
        return accessor.selectedText(from: element)
    }
}
