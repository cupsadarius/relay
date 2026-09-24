import Foundation

enum AppleCleanupAvailability: Equatable, Sendable {
    case available
    case unavailable(AppleUnavailability)
}

/// A generation error an engine reports without any error text.
enum CleanupEngineError: Error, Equatable, Sendable {
    case generation(GenerationFailureKind)
}

enum MLXCleanupRuntimeError: Error, Equatable, Sendable {
    /// The model is not on disk. Dictation never downloads.
    case notDownloaded
    /// The requested model is not the loaded one (or a transition is running).
    case notLoaded
}

enum MLXCleanupReadiness: Equatable, Sendable {
    case ready
    case notLoaded
    case loading
    /// The most recent load of this model threw.
    case loadFailed
    case unloading
}

enum MLXCleanupRuntimeEvent: Equatable, Sendable {
    case loaded(CleanupModelID, elapsed: Duration)
    case unloaded(CleanupModelID, cause: CleanupUnloadCause)
}

/// What the service and the Test tool need from the Apple backend (`AppleCleanupRuntime`, Task 23).
protocol AppleCleanupBackending: Sendable {
    func availability() -> AppleCleanupAvailability
    func supportsLocale(_ locale: Locale) -> Bool
    func prewarm(instructions: String)
    /// Drops the prewarmed session, if any (memory pressure).
    func releasePrewarm()
    /// Throws `CleanupSlotError`, `CleanupEngineError.generation`, or `CancellationError`.
    func generate(_ request: CleanupRequest, priority: CleanupPriority) async throws -> String
}

/// What the service, the Test tool and the MLX manager need from `MLXCleanupRuntime` (Task 21).
protocol MLXCleanupRuntimeServing: Sendable {
    var events: AsyncStream<MLXCleanupRuntimeEvent> { get }
    /// Offline presence: the model's verified folder exists.
    func isPresent(_ id: CleanupModelID) -> Bool
    func readiness(for id: CleanupModelID) async -> MLXCleanupReadiness
    /// Loads from disk only; throws `MLXCleanupRuntimeError.notDownloaded` without touching disk
    /// or network when the model is absent.
    func ensureLoaded(_ id: CleanupModelID) async throws
    /// Throws `MLXCleanupRuntimeError.notLoaded`, `CleanupSlotError`, or the engine's error.
    func generate(_ request: CleanupRequest, priority: CleanupPriority) async throws -> String
    /// Re-arms the idle-unload timer.
    func touch() async
    func unload(cause: CleanupUnloadCause) async
    func unload(ifInvolving id: CleanupModelID) async
    /// Retires the active generation only when `id` is the model actually loaded.
    func retireGeneration(ifInvolving id: CleanupModelID) async
}
