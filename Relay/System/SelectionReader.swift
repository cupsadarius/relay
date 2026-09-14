import Foundation

@MainActor
protocol SelectionReading {
    func readSelection() throws -> SelectionResult
}

enum SelectionSource: Equatable, Sendable { case accessibility, clipboard }
struct SelectionResult: Equatable, Sendable { let text: String; let source: SelectionSource }

@MainActor
protocol AccessibilityReading {
    func selectedText() -> String?
}

@MainActor
protocol ClipboardReading {
    func copyCurrentSelection() throws -> String?
}

enum SelectionReadingError: Error, Equatable, LocalizedError {
    case noUsableSelection

    var errorDescription: String? {
        "No selected text found. Select text and try again."
    }
}

@MainActor
final class SelectionReader: SelectionReading {
    private let accessibility: any AccessibilityReading
    private let clipboard: any ClipboardReading

    init(accessibility: any AccessibilityReading, clipboard: any ClipboardReading) {
        self.accessibility = accessibility
        self.clipboard = clipboard
    }

    func readSelection() throws -> SelectionResult {
        if let selection = usable(accessibility.selectedText()) {
            return .init(text: selection, source: .accessibility)
        }

        do {
            if let selection = usable(try clipboard.copyCurrentSelection()) {
                return .init(text: selection, source: .clipboard)
            }
        } catch {
            throw SelectionReadingError.noUsableSelection
        }

        throw SelectionReadingError.noUsableSelection
    }

    private func usable(_ selection: String?) -> String? {
        guard let selection,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return selection
    }
}
