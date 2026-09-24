import Foundation

@MainActor
protocol TranscriptCleaning: AnyObject, Sendable {
    /// Throws only `CancellationError`. Every other failure is a `.fellBack` result. `onAttempt`
    /// runs once, on the main actor, right before generation starts (after every gate passed),
    /// and never for a gated-out request.
    func cleanForInsertion(
        _ text: String,
        onAttempt: @MainActor () -> Void
    ) async throws(CancellationError) -> TranscriptCleanupResult

    /// Dictation `start()`, settings changes and launch call this. Best-effort, never blocks,
    /// never downloads.
    func prewarm()
}

/// Always `.notAttempted`. The `DictationCoordinator` default, so existing call sites compile
/// unchanged. `nonisolated init` makes it a legal default argument of a `@MainActor` init
/// (decision 18).
@MainActor
final class NoopTranscriptCleaner: TranscriptCleaning {
    nonisolated init() {}

    func cleanForInsertion(
        _ text: String,
        onAttempt: @MainActor () -> Void
    ) async throws(CancellationError) -> TranscriptCleanupResult {
        .notAttempted(text)
    }

    func prewarm() {}
}
