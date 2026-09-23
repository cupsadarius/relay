import ApplicationServices
import Foundation

@MainActor
protocol SelectionReading {
    func readSelection() async throws -> SelectionResult
}

enum SelectionSource: Equatable, Sendable { case accessibility, clipboard }
struct SelectionResult: Equatable, Sendable { let text: String; let source: SelectionSource }

@MainActor
protocol AccessibilityReading {
    func selectedText() -> String?
}

@MainActor
protocol ClipboardReading {
    func copyCurrentSelection() async throws -> String?
}

enum SelectionReadingError: Error, Equatable, LocalizedError {
    case noUsableSelection
    case accessibilityPermissionDenied

    var errorDescription: String? {
        switch self {
        case .noUsableSelection:
            "No selected text found. Select text and try again."
        case .accessibilityPermissionDenied:
            "Relay needs Accessibility permission to read selected text. Enable it in System Settings › Privacy & Security › Accessibility."
        }
    }
}

@MainActor
final class SelectionReader: SelectionReading {
    private let accessibility: any AccessibilityReading
    private let clipboard: any ClipboardReading
    private let canReadSelection: () -> Bool

    /// - Parameter canReadSelection: whether Relay may read the AX tree or post ⌘C at all
    ///   (Accessibility trust). Checked only after the AX read came back empty.
    init(
        accessibility: any AccessibilityReading,
        clipboard: any ClipboardReading,
        canReadSelection: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.canReadSelection = canReadSelection
    }

    func readSelection() async throws -> SelectionResult {
        if let selection = usable(accessibility.selectedText()) {
            return .init(text: selection, source: .accessibility)
        }
        guard canReadSelection() else {
            throw SelectionReadingError.accessibilityPermissionDenied
        }
        do {
            if let selection = usable(try await clipboard.copyCurrentSelection()) {
                return .init(text: selection, source: .clipboard)
            }
        } catch is CancellationError {
            // A cancelled caller doesn't want a substitute "no selection" error — it wants to
            // know its own request was cancelled, not that the selection was empty.
            throw CancellationError()
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
