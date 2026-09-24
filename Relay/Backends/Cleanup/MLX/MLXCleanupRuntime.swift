import Foundation
import os

/// The one resident MLX cleanup model (spec §13.4). Single-flight transitions exactly like
/// `WhisperRuntime`; unloads drain the shared generation slot (zombies included) first; an idle
/// timer unloads after `idleUnloadAfter` without a generation, prewarm or touch. Loads only from
/// a verified local folder and never downloads. Exclusion never relies on actor reentrancy: all
/// of it is explicit state re-checked after every `await`.
actor MLXCleanupRuntime: MLXCleanupRuntimeServing {
    private struct Transition {
        let target: CleanupModelID?
        let from: CleanupModelID?
        let token: UUID
        let task: Task<Void, Error>
    }

    nonisolated let events: AsyncStream<MLXCleanupRuntimeEvent>
    private nonisolated let eventSink: AsyncStream<MLXCleanupRuntimeEvent>.Continuation
    private nonisolated let presence: @Sendable (CleanupModelID) -> Bool

    private let engine: any MLXCleanupEngine
    private let directory: @Sendable (CleanupModelID) -> URL
    private let slot: CleanupGenerationSlot
    private let idleUnloadAfter: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "cleanup-mlx")

    private var loaded: (id: CleanupModelID, model: any LoadedMLXCleanupModel)?
    private var inFlightTransition: Transition?
    private var lastLoadFailure: CleanupModelID?
    private var idleTimer: Task<Void, Never>?
    private var idleToken: UUID?

    init(
        engine: any MLXCleanupEngine,
        directory: @escaping @Sendable (CleanupModelID) -> URL,
        isPresent: @escaping @Sendable (CleanupModelID) -> Bool,
        slot: CleanupGenerationSlot,
        idleUnloadAfter: Duration = .seconds(600),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: MLXCleanupRuntimeEvent.self, bufferingPolicy: .bufferingNewest(16))
        events = stream
        eventSink = continuation
        self.engine = engine
        self.directory = directory
        presence = isPresent
        self.slot = slot
        self.idleUnloadAfter = idleUnloadAfter
        self.sleep = sleep
        self.now = now
    }

    nonisolated func isPresent(_ id: CleanupModelID) -> Bool { presence(id) }

    func readiness(for id: CleanupModelID) -> MLXCleanupReadiness {
        if let transition = inFlightTransition {
            if transition.target == id { return .loading }
            if transition.target == nil { return .unloading }
            return .notLoaded
        }
        if loaded?.id == id { return .ready }
        return lastLoadFailure == id ? .loadFailed : .notLoaded
    }

    func ensureLoaded(_ id: CleanupModelID) async throws {
        guard id.isMLX, presence(id) else { throw MLXCleanupRuntimeError.notDownloaded }
        try await transition(to: id, cause: .switchModel)
        armIdleTimer()
    }

    func generate(_ request: CleanupRequest, priority: CleanupPriority) async throws -> String {
        guard inFlightTransition == nil, let loaded, loaded.id == request.modelID else { throw MLXCleanupRuntimeError.notLoaded }
        let model = loaded.model
        defer { armIdleTimer() }
        let result = try await slot.run(priority) { try await model.generate(request) }
        // The slot has no deadline of its own: a non-cooperative engine can keep running past the
        // caller's own cancellation. Discard that late "zombie" result here rather than hand it
        // back to a caller that has already moved on (controller decision, Task 21).
        if Task.isCancelled { throw CancellationError() }
        return result
    }

    func touch() {
        guard loaded != nil else { return }
        armIdleTimer()
    }

    func unload(cause: CleanupUnloadCause) async {
        try? await transition(to: nil, cause: cause)
    }

    /// `WhisperRuntime.unload(ifInvolving:)` semantics: waits out any transition to or from `id`,
    /// then unloads if `id` is loaded.
    func unload(ifInvolving id: CleanupModelID) async {
        while let inFlight = inFlightTransition, inFlight.target == id || inFlight.from == id {
            _ = try? await inFlight.task.value
        }
        if loaded?.id == id { await unload(cause: .removal) }
    }

    func retireGeneration() async {
        await slot.retire()
    }

    private func transition(to target: CleanupModelID?, cause: CleanupUnloadCause) async throws {
        while true {
            if inFlightTransition == nil, loaded?.id == target { return }
            guard let inFlight = inFlightTransition else { break }
            if inFlight.target == target {
                try await inFlight.task.value
            } else {
                _ = try? await inFlight.task.value
            }
        }
        let token = UUID()
        let task = Task { try await self.performTransition(to: target, cause: cause, token: token) }
        inFlightTransition = Transition(target: target, from: loaded?.id, token: token, task: task)
        try await task.value
    }

    private func performTransition(to target: CleanupModelID?, cause: CleanupUnloadCause, token: UUID) async throws {
        defer {
            if inFlightTransition?.token == token { inFlightTransition = nil }
        }
        if let current = loaded {
            loaded = nil
            cancelIdleTimer()
            await slot.close()
            await current.model.unload()
            await engine.clearCache()
            await slot.open()
            eventSink.yield(.unloaded(current.id, cause: cause))
            logger.debug("Cleanup model unloaded")
        }
        guard let target else { return }
        // Re-check presence right before the load: `ensureLoaded`'s own check can be stale by the
        // time this transition actually runs (it may have waited behind another in-flight
        // transition, e.g. an idle unload), and a removal in between must not load a model whose
        // files are already gone (review fix 3).
        guard presence(target) else {
            lastLoadFailure = target
            throw MLXCleanupRuntimeError.notDownloaded
        }
        let started = now()
        do {
            let model = try await engine.load(directory: directory(target))
            loaded = (id: target, model: model)
            lastLoadFailure = nil
            eventSink.yield(.loaded(target, elapsed: now() - started))
            logger.debug("Cleanup model loaded")
        } catch {
            lastLoadFailure = target
            throw error
        }
    }

    private func armIdleTimer() {
        guard loaded != nil else { return }
        idleTimer?.cancel()
        let token = UUID()
        idleToken = token
        let sleep = sleep
        let delay = idleUnloadAfter
        idleTimer = Task {
            do { try await sleep(delay) } catch { return }
            await self.idleTimerFired(token)
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
        idleToken = nil
    }

    private func idleTimerFired(_ token: UUID) async {
        guard idleToken == token, loaded != nil else { return }
        await unload(cause: .idle)
    }
}
