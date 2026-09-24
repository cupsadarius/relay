import Foundation
import Observation

/// The Settings Test tool (spec §17): one cleanup of user-entered text within a 10 s budget,
/// showing raw output, timing and the validator verdict. Never changes the selection, inserts text,
/// stores input or output, downloads, or records diagnostics.
@MainActor
@Observable
final class DictationCleanupTester {
    struct Report: Equatable, Sendable {
        let rawOutput: String
        let verdict: String
        /// What production would insert: the cleaned text, or the input on a fallback.
        let wouldInsert: String
        let loadTime: Duration?
        let generationTime: Duration
    }

    enum Phase: Equatable, Sendable {
        case idle, loading, running
        case finished(Report)
        case timedOut, cancelledByDictation, cancelledModelRemoved, busy, modelUnavailable, failed

        var isRunning: Bool { self == .loading || self == .running }

        var title: String {
            switch self {
            case .idle: ""
            case .loading: "Loading model…"
            case .running: "Running…"
            case .finished: "Finished"
            case .timedOut: "Timed out"
            case .cancelledByDictation: "Cancelled by dictation"
            case .cancelledModelRemoved: "Cancelled: model removed"
            case .busy: "Busy: dictation in progress"
            case .modelUnavailable: "Model unavailable"
            case .failed: "Failed"
            }
        }
    }

    enum CancelReason: Sendable {
        case modelRemoved
    }

    nonisolated static let budget: Duration = .seconds(10)
    /// Spike S3 (Task 3): `false` when the 0.6B cold load is ≥ 8 s, so the budget covers generation only.
    nonisolated static let budgetIncludesLoad = true
    nonisolated static let defaultSample =
        "uh change the user service no wait the auth service to use refresh tokens and don't change the API"

    var input: String = DictationCleanupTester.defaultSample
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let apple: any AppleCleanupBackending
    @ObservationIgnored private let mlx: any MLXCleanupRuntimeServing
    @ObservationIgnored private let validator: CleanupSafetyValidator
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelPhase: Phase?

    init(
        apple: any AppleCleanupBackending,
        mlx: any MLXCleanupRuntimeServing,
        validator: CleanupSafetyValidator = .init(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.apple = apple
        self.mlx = mlx
        self.validator = validator
        self.sleep = sleep
        self.now = now
    }

    func run(model: CleanupModelID) {
        guard !phase.isRunning else { return }
        cancelPhase = nil
        phase = .running
        let text = input
        task = Task { [weak self] in await self?.perform(model: model, text: text) }
    }

    /// Model removal (spec §14.3). A no-op unless a test is running.
    func cancelRunningTest(reason: CancelReason) {
        guard phase.isRunning, let task else { return }
        switch reason {
        case .modelRemoved: cancelPhase = .cancelledModelRemoved
        }
        task.cancel()
    }

    private func perform(model: CleanupModelID, text: String) async {
        let start = now()
        var loadTime: Duration?
        if model.isMLX {
            guard mlx.isPresent(model) else { return finish(.modelUnavailable) }
            if await mlx.readiness(for: model) != .ready {
                phase = .loading
                let loadStart = now()
                do {
                    try await mlx.ensureLoaded(model)
                } catch {
                    return finish(.modelUnavailable)
                }
                loadTime = now() - loadStart
            }
        } else {
            guard apple.availability() == .available else { return finish(.modelUnavailable) }
        }

        phase = .running
        let spent = Self.budgetIncludesLoad ? now() - start : .zero
        let remaining = max(.zero, Self.budget - spent)
        // Same pre-pass as production (spec §10.1); a fallback still shows the original text.
        let prePassed = SelfCorrectionPrePass.apply(to: text)
        let request = CleanupRequest(
            modelID: model, instructions: CleanupPrompt.instructions, input: prePassed.text,
            maxOutputTokens: CleanupPrompt.maxOutputTokens(for: prePassed.text)
        )
        let apple = apple
        let mlx = mlx
        let generationStart = now()
        let outcome: DeadlineOutcome<String>
        do {
            outcome = try await withCleanupDeadline(remaining, sleep: sleep) {
                if model.isMLX { return try await mlx.generate(request, priority: .test) }
                return try await apple.generate(request, priority: .test)
            }
        } catch {
            return finish(nil)
        }
        let generationTime = now() - generationStart

        switch outcome {
        case .timedOut:
            finish(.timedOut)
        case .failure(CleanupSlotError.preempted):
            finish(.cancelledByDictation)
        case .failure(CleanupSlotError.busy):
            finish(.busy)
        case .failure(MLXCleanupRuntimeError.notLoaded), .failure(MLXCleanupRuntimeError.notDownloaded):
            finish(.modelUnavailable)
        case .failure:
            finish(.failed)
        case let .value(raw):
            let report: Report
            switch validator.validate(input: prePassed.text, output: raw, replaced: prePassed.replaced) {
            case let .accept(cleaned):
                report = Report(rawOutput: raw, verdict: "Would insert", wouldInsert: cleaned, loadTime: loadTime, generationTime: generationTime)
            case let .reject(rejection):
                report = Report(
                    rawOutput: raw, verdict: "Would fall back: \(rejection.label)", wouldInsert: text,
                    loadTime: loadTime, generationTime: generationTime
                )
            }
            finish(.finished(report))
        }
    }

    /// A pending cancellation reason always wins over whatever the run itself produced.
    private func finish(_ result: Phase?) {
        phase = cancelPhase ?? result ?? .failed
        cancelPhase = nil
        task = nil
    }
}
