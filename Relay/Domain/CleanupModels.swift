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
    case empty, reasoningMarkup, wrapper, refusal, tooLong, literalInvented, literalMissing, contentDropped

    var label: String {
        switch self {
        case .empty: "empty output"
        case .reasoningMarkup: "reasoning markup"
        case .wrapper: "wrapper text"
        case .refusal: "assistant reply"
        case .tooLong: "output too long"
        case .literalInvented: "literal invented"
        case .literalMissing: "literal missing"
        case .contentDropped: "content dropped"
        }
    }
}

/// Synchronous, actor-agnostic read of the one global cleanup selection. A stale or unknown
/// stored id reads as `nil`.
typealias CleanupModelSelection = @Sendable () -> CleanupModelID?

/// Write half; persists through `SettingsController` (mirrors `WhisperModelSelectionWriter`).
typealias CleanupModelSelectionWriter = @MainActor @Sendable (CleanupModelID?) -> Void

/// Why the Apple model cannot run (spec §12.2).
enum AppleUnavailability: Equatable, Sendable {
    case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unknown

    /// Row state text in Settings.
    var rowText: String {
        switch self {
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .deviceNotEligible: "Not supported on this Mac"
        case .modelNotReady: "Apple model is not ready yet"
        case .unknown: "Apple model is unavailable"
        }
    }

    var label: String {
        switch self {
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .deviceNotEligible: "not supported on this Mac"
        case .modelNotReady: "Apple model not ready"
        case .unknown: "Apple model unavailable"
        }
    }
}

/// A generation failure, reduced to a closed set (spec §12.4). Never carries error text.
enum GenerationFailureKind: Equatable, Sendable, CaseIterable {
    case exceededContextWindow, assetsUnavailable, guardrailViolation, unsupportedGuide, unsupportedLanguageOrLocale
    case decodingFailure, rateLimited, concurrentRequests, refusal, mlxEngine, other

    var label: String {
        switch self {
        case .exceededContextWindow: "context window exceeded"
        case .assetsUnavailable: "assets unavailable"
        case .guardrailViolation: "guardrail violation"
        case .unsupportedGuide: "unsupported guide"
        case .unsupportedLanguageOrLocale: "unsupported language or locale"
        case .decodingFailure: "decoding failure"
        case .rateLimited: "rate limited"
        case .concurrentRequests: "concurrent requests"
        case .refusal: "refusal"
        case .mlxEngine: "MLX engine error"
        case .other: "other"
        }
    }
}

/// Every reason cleanup returns the input unchanged (spec §8.1; decision 5 drops `selectionUnknown`).
enum CleanupFallbackReason: Equatable, Sendable {
    case appleUnavailable(AppleUnavailability)
    case unsupportedLocale
    case modelNotDownloaded
    case modelCold
    case runtimeBusy
    case loadFailed
    case generationFailed(GenerationFailureKind)
    case timedOut
    case inputTooLong
    case validationRejected(ValidationRejection)

    var label: String {
        switch self {
        case let .appleUnavailable(reason): reason.label
        case .unsupportedLocale: "unsupported locale"
        case .modelNotDownloaded: "model not downloaded"
        case .modelCold: "model cold"
        case .runtimeBusy: "runtime busy"
        case .loadFailed: "model load failed"
        case let .generationFailed(kind): "generation: \(kind.label)"
        case .timedOut: "timed out"
        case .inputTooLong: "input too long"
        case let .validationRejected(rejection): "validation: \(rejection.label)"
        }
    }
}

enum CleanupOutcome: Equatable, Sendable {
    /// Disabled, or no (valid) selection. Records nothing; the user sees nothing different.
    case notAttempted
    case cleaned
    case fellBack(CleanupFallbackReason)
}

struct TranscriptCleanupResult: Equatable, Sendable {
    /// Cleaned text, or the input unchanged.
    let text: String
    let modelID: CleanupModelID?
    let outcome: CleanupOutcome
    let elapsed: Duration?

    static func notAttempted(_ text: String) -> Self {
        TranscriptCleanupResult(text: text, modelID: nil, outcome: .notAttempted, elapsed: nil)
    }
}

enum CleanupLatencyBucket: Equatable, Sendable {
    case under250Milliseconds, under500Milliseconds, underOneSecond, upTo2Point5Seconds, over2Point5Seconds

    init(_ elapsed: Duration) {
        switch elapsed {
        case ..<Duration.milliseconds(250): self = .under250Milliseconds
        case ..<Duration.milliseconds(500): self = .under500Milliseconds
        case ..<Duration.seconds(1): self = .underOneSecond
        case ...Duration.milliseconds(2500): self = .upTo2Point5Seconds
        default: self = .over2Point5Seconds
        }
    }

    var label: String {
        switch self {
        case .under250Milliseconds: "<250 ms"
        case .under500Milliseconds: "250–500 ms"
        case .underOneSecond: "0.5–1 s"
        case .upTo2Point5Seconds: "1–2.5 s"
        case .over2Point5Seconds: ">2.5 s"
        }
    }
}

enum CleanupUnloadCause: Equatable, Sendable {
    case idle, memoryPressure, removal, switchModel

    var label: String {
        switch self {
        case .idle: "idle"
        case .memoryPressure: "memory pressure"
        case .removal: "removal"
        case .switchModel: "model switch"
        }
    }
}
