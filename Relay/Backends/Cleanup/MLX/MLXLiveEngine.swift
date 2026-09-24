import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Live `MLXCleanupEngine`. Loads only from a verified local folder through
/// `LLMModelFactory.loadContainer(from:using:)` with Relay's own tokenizer loader (spec §13.4).
struct MLXLiveEngine: MLXCleanupEngine {
    /// GPU buffer cache cap, set before every load (spec §9.3).
    static let gpuCacheLimitBytes = 64 * 1024 * 1024
    /// Greedy decoding: cleanup has one right answer, and sampling only adds run-to-run drift.
    static let temperature: Float = 0

    func load(directory: URL) async throws -> any LoadedMLXCleanupModel {
        Memory.cacheLimit = Self.gpuCacheLimitBytes
        let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: RelayTokenizerLoader())
        return MLXLoadedCleanupModel(container: container)
    }

    func clearCache() async {
        Memory.clearCache()
    }
}

/// One loaded Qwen3 container. Dropping the last reference (the runtime sets `loaded = nil`)
/// releases the weights; `unload()` has nothing else to free.
struct MLXLoadedCleanupModel: LoadedMLXCleanupModel {
    let container: ModelContainer

    func generate(_ request: CleanupRequest) async throws -> String {
        try await generate(request, onFirstChunk: nil)
    }

    /// The chat turns for one request: `request.instructions` and `request.examples` (the
    /// caller's EFFECTIVE prompt — a saved override, or `CleanupPrompt`'s defaults) rendered as
    /// prior user/assistant turns, then the real input (spec §10 addendum). Pure and separated out
    /// so it is testable without a loaded `ModelContainer`.
    static func chatMessages(for request: CleanupRequest) -> [Chat.Message] {
        let examples = request.examples.flatMap { [Chat.Message.user($0.input), .assistant($0.output)] }
        return [.system(request.instructions)] + examples + [.user(request.input)]
    }

    /// `onFirstChunk` exists for spike S3's first-token timing only.
    func generate(_ request: CleanupRequest, onFirstChunk: (@Sendable () -> Void)?) async throws -> String {
        let input = try await container.prepare(input: UserInput(chat: Self.chatMessages(for: request)))
        let parameters = GenerateParameters(
            maxTokens: request.maxOutputTokens,
            temperature: MLXLiveEngine.temperature
        )
        var output = ""
        var sawChunk = false
        // Breaking out of the loop terminates the stream, whose onTermination cancels MLX's
        // generation task, so cancellation stops generation at the next token.
        for await generation in try await container.generate(input: input, parameters: parameters) {
            if Task.isCancelled { break }
            if let chunk = generation.chunk {
                if !sawChunk {
                    sawChunk = true
                    onFirstChunk?()
                }
                output += chunk
            }
        }
        try Task.checkCancellation()
        return output
    }

    func unload() async {}
}
