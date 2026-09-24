import Foundation

/// The seam between `MLXCleanupRuntime` and MLX (a live engine in production, a fake in tests).
/// An engine only loads an already-verified local folder; it never downloads and never decides
/// which model is active.
protocol MLXCleanupEngine: Sendable {
    func load(directory: URL) async throws -> any LoadedMLXCleanupModel
    /// Frees MLX's GPU buffer cache after an unload.
    func clearCache() async
}

/// One loaded model. `MLXCleanupRuntime` keeps at most one resident and calls `unload()` before
/// loading a replacement. Each `generate` uses a fresh KV cache and never logs text.
protocol LoadedMLXCleanupModel: Sendable {
    func generate(_ request: CleanupRequest) async throws -> String
    func unload() async
}
