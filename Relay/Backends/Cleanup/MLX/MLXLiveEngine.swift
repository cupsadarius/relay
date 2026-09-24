import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Live `MLXCleanupEngine`. Loads only from a verified local folder through
/// `LLMModelFactory.loadContainer(from:using:)` with Relay's own tokenizer loader (spec §13.4).
struct MLXLiveEngine: MLXCleanupEngine {
    /// GPU buffer cache cap, set before every load (spec §9.3).
    static let gpuCacheLimitBytes = 64 * 1024 * 1024
    static let temperature: Float = 0.2
    static let topP: Float = 0.9

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

    /// `onFirstChunk` exists for spike S3's first-token timing only.
    func generate(_ request: CleanupRequest, onFirstChunk: (@Sendable () -> Void)?) async throws -> String {
        let input = try await container.prepare(
            input: UserInput(chat: [.system(request.instructions), .user(request.input)])
        )
        let parameters = GenerateParameters(
            maxTokens: request.maxOutputTokens,
            temperature: MLXLiveEngine.temperature,
            topP: MLXLiveEngine.topP
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
