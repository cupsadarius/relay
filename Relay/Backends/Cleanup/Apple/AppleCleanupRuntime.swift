import Foundation

/// The FoundationModels boundary, with no FoundationModels types in its signature.
protocol AppleCleanupEngine: Sendable {
    func availability() -> AppleCleanupAvailability
    func supportsLocale(_ locale: Locale) -> Bool
    func prewarm(instructions: String)
    /// Throws `CleanupEngineError.generation` or `CancellationError`, never raw FM errors.
    func respond(_ request: CleanupRequest) async throws -> String
}

/// `AppleCleanupBackending` over an engine, with generations guarded by the shared slot (§8.4).
struct AppleCleanupRuntime: AppleCleanupBackending {
    private let engine: any AppleCleanupEngine
    private let slot: CleanupGenerationSlot

    init(engine: any AppleCleanupEngine, slot: CleanupGenerationSlot) {
        self.engine = engine
        self.slot = slot
    }

    func availability() -> AppleCleanupAvailability { engine.availability() }
    func supportsLocale(_ locale: Locale) -> Bool { engine.supportsLocale(locale) }
    func prewarm(instructions: String) { engine.prewarm(instructions: instructions) }

    func generate(_ request: CleanupRequest, priority: CleanupPriority) async throws -> String {
        let engine = engine
        return try await slot.run(priority) { try await engine.respond(request) }
    }
}
