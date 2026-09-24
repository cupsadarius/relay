import Foundation

/// Optional, local, fail-open cleanup of the final dictation transcript (spec §6.4, §8). Owns the
/// gates, the production deadline, validation and structural diagnostics. Never downloads, never
/// writes the selection, never logs text.
@MainActor
final class TranscriptCleanupService: TranscriptCleaning {
    nonisolated static let maxInputCharacters = 2_000

    private let isEnabled: @Sendable () -> Bool
    private let selection: CleanupModelSelection
    private let apple: any AppleCleanupBackending
    private let mlx: any MLXCleanupRuntimeServing
    private let validator: CleanupSafetyValidator
    private let productionTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let locale: @Sendable () -> Locale
    private let diagnostics: DiagnosticsRecorder?

    init(
        isEnabled: @escaping @Sendable () -> Bool,
        selection: @escaping CleanupModelSelection,
        apple: any AppleCleanupBackending,
        mlx: any MLXCleanupRuntimeServing,
        validator: CleanupSafetyValidator = .init(),
        productionTimeout: Duration = .milliseconds(2500),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        locale: @escaping @Sendable () -> Locale = { .current },
        memoryPressure: (any MemoryPressureMonitoring)? = nil,
        diagnostics: DiagnosticsRecorder?
    ) {
        self.isEnabled = isEnabled
        self.selection = selection
        self.apple = apple
        self.mlx = mlx
        self.validator = validator
        self.productionTimeout = productionTimeout
        self.sleep = sleep
        self.now = now
        self.locale = locale
        self.diagnostics = diagnostics

        memoryPressure?.start { [mlx] in
            Task { await mlx.unload(cause: .memoryPressure) }
        }
        // The service is the runtime's only event consumer. The loop holds `self` weakly and ends
        // with the stream.
        let events = mlx.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.record(event)
            }
        }
    }

    private func record(_ event: MLXCleanupRuntimeEvent) {
        switch event {
        case let .loaded(id, elapsed):
            diagnostics?.record(.dictationCleanup(.modelLoaded(model: id, elapsed: CleanupLatencyBucket(elapsed))))
        case let .unloaded(id, cause):
            diagnostics?.record(.dictationCleanup(.modelUnloaded(model: id, cause: cause)))
        }
    }

    func cleanForInsertion(
        _ text: String,
        onAttempt: @MainActor () -> Void
    ) async throws(CancellationError) -> TranscriptCleanupResult {
        guard isEnabled(), let id = selection() else { return .notAttempted(text) }
        guard text.count <= Self.maxInputCharacters else { return fellBack(text, id, .inputTooLong) }
        // v1 prompts and validator cue words are English-only (spec §12.3), for both engines.
        guard Self.isEnglish(locale()) else { return fellBack(text, id, .unsupportedLocale) }

        let request = CleanupRequest(
            modelID: id,
            instructions: CleanupPrompt.instructions,
            input: text,
            maxOutputTokens: CleanupPrompt.maxOutputTokens(for: text)
        )
        let operation: @Sendable () async throws -> String
        if id.isMLX {
            guard mlx.isPresent(id) else { return fellBack(text, id, .modelNotDownloaded) }
            switch await mlx.readiness(for: id) {
            case .ready:
                break
            case .loading:
                return fellBack(text, id, .modelCold)
            case .notLoaded:
                startBackgroundLoad(id)
                return fellBack(text, id, .modelCold)
            case .loadFailed:
                startBackgroundLoad(id)
                return fellBack(text, id, .loadFailed)
            case .unloading:
                return fellBack(text, id, .runtimeBusy)
            }
            if Task.isCancelled { throw CancellationError() }
            let mlx = mlx
            operation = { try await mlx.generate(request, priority: .production) }
        } else {
            if case let .unavailable(reason) = apple.availability() { return fellBack(text, id, .appleUnavailable(reason)) }
            guard apple.supportsLocale(locale()) else { return fellBack(text, id, .unsupportedLocale) }
            let apple = apple
            operation = { try await apple.generate(request, priority: .production) }
        }

        onAttempt()
        diagnostics?.record(.dictationCleanup(.started(model: id)))
        let started = now()
        let outcome: DeadlineOutcome<String>
        do {
            outcome = try await withCleanupDeadline(productionTimeout, sleep: sleep, operation: operation)
        } catch {
            diagnostics?.record(.dictationCleanup(.cancelled(model: id)))
            throw error
        }
        let elapsed = now() - started

        switch outcome {
        case .timedOut:
            return fellBack(text, id, .timedOut, elapsed: elapsed)
        case let .failure(error):
            return fellBack(text, id, Self.reason(for: error, model: id), elapsed: elapsed)
        case let .value(raw):
            switch validator.validate(input: text, output: raw) {
            case let .accept(cleaned):
                diagnostics?.record(.dictationCleanup(.finished(model: id, elapsed: CleanupLatencyBucket(elapsed))))
                return TranscriptCleanupResult(text: cleaned, modelID: id, outcome: .cleaned, elapsed: elapsed)
            case let .reject(rejection):
                return fellBack(text, id, .validationRejected(rejection), elapsed: elapsed)
            }
        }
    }

    func prewarm() {
        guard isEnabled(), let id = selection() else { return }
        if id.isMLX {
            guard mlx.isPresent(id) else { return }
            let mlx = mlx
            Task {
                try? await mlx.ensureLoaded(id)
                await mlx.touch()
            }
        } else {
            guard case .available = apple.availability() else { return }
            apple.prewarm(instructions: CleanupPrompt.instructions)
        }
    }

    nonisolated static func isEnglish(_ locale: Locale) -> Bool {
        locale.language.languageCode == .english
    }

    nonisolated static func reason(for error: any Error, model: CleanupModelID) -> CleanupFallbackReason {
        switch error {
        case CleanupSlotError.busy, CleanupSlotError.preempted, CleanupSlotError.closed: .runtimeBusy
        case MLXCleanupRuntimeError.notLoaded: .modelCold
        case MLXCleanupRuntimeError.notDownloaded: .modelNotDownloaded
        case let CleanupEngineError.generation(kind): .generationFailed(kind)
        default: .generationFailed(model.isMLX ? .mlxEngine : .other)
        }
    }

    private func fellBack(
        _ text: String,
        _ id: CleanupModelID,
        _ reason: CleanupFallbackReason,
        elapsed: Duration? = nil
    ) -> TranscriptCleanupResult {
        diagnostics?.record(.dictationCleanup(.fellBack(model: id, reason: reason)))
        return TranscriptCleanupResult(text: text, modelID: id, outcome: .fellBack(reason), elapsed: elapsed)
    }

    /// Cold at finish: fail open now, and make sure the next dictation is warm (spec §9.2).
    private func startBackgroundLoad(_ id: CleanupModelID) {
        let mlx = mlx
        Task { try? await mlx.ensureLoaded(id) }
    }
}
