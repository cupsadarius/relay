import Foundation

/// A dictation-cleanup model. Raw values are persisted in `AppSettings.selectedCleanupModelID`
/// and must never change (spec §6.2).
enum CleanupModelID: String, CaseIterable, Sendable {
    case appleSystem = "apple.system-language-model"
    case qwen3_0_6b = "mlx.qwen3-0.6b-4bit"
    case qwen3_1_7b = "mlx.qwen3-1.7b-4bit"

    var isMLX: Bool { self != .appleSystem }

    /// Fixed, user-facing and diagnostics-safe name.
    var displayName: String {
        switch self {
        case .appleSystem: "Apple Intelligence"
        case .qwen3_0_6b: "Qwen3 0.6B"
        case .qwen3_1_7b: "Qwen3 1.7B"
        }
    }

    var diagnosticName: String { displayName }
}

/// One cleanup generation request. Engines never log any of it.
struct CleanupRequest: Equatable, Sendable {
    let modelID: CleanupModelID
    let instructions: String
    let input: String
    let maxOutputTokens: Int
}

/// Why the validator refused a model output (spec §11.1). Cases are declared in check order.
/// Raw values are used by the eval corpus fixture.
enum ValidationRejection: String, CaseIterable, Codable, Equatable, Sendable {
    case empty, reasoningMarkup, wrapper, tooLong, literalInvented, literalMissing

    var label: String {
        switch self {
        case .empty: "empty output"
        case .reasoningMarkup: "reasoning markup"
        case .wrapper: "wrapper text"
        case .tooLong: "output too long"
        case .literalInvented: "literal invented"
        case .literalMissing: "literal missing"
        }
    }
}

/// Synchronous, actor-agnostic read of the one global cleanup selection. A stale or unknown
/// stored id reads as `nil`.
typealias CleanupModelSelection = @Sendable () -> CleanupModelID?

/// Write half; persists through `SettingsController` (mirrors `WhisperModelSelectionWriter`).
typealias CleanupModelSelectionWriter = @MainActor @Sendable (CleanupModelID?) -> Void
