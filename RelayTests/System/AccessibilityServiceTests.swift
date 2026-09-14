import ApplicationServices
import XCTest
@testable import Relay

@MainActor
final class AccessibilityServiceTests: XCTestCase {
    func testUnexpectedFocusedAttributeTypeIsUnavailable() {
        let accessor = FakeAccessibilityElementAccessor(focusedValue: "not an AX element" as CFString)

        XCTAssertNil(AccessibilityService(accessor: accessor).selectedText())
        XCTAssertEqual(accessor.selectedTextCallCount, 0)
    }
}

@MainActor
private final class FakeAccessibilityElementAccessor: AccessibilityElementAccessing {
    let focusedValue: CFTypeRef?
    private(set) var selectedTextCallCount = 0

    init(focusedValue: CFTypeRef?) {
        self.focusedValue = focusedValue
    }

    func focusedElementValue() -> CFTypeRef? {
        focusedValue
    }

    func selectedText(from element: AXUIElement) -> String? {
        selectedTextCallCount += 1
        return "unexpected"
    }
}
