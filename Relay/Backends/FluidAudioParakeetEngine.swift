import FluidAudio
import Foundation

/// Production `ParakeetEngine` backed by FluidAudio's Parakeet TDT v3 model. Loads and runs the
/// model entirely on-device; the only network access this type performs is the explicit
/// HuggingFace download triggered by `load(allowDownload: true)`.
actor FluidAudioParakeetEngine: ParakeetEngine {
    private static let version: AsrModelVersion = .v3

    /// The directory FluidAudio stores (or expects to find) the Parakeet model files in.
    let modelDirectory: URL

    private var manager: AsrManager?

    init(modelDirectory: URL = AsrModels.defaultCacheDirectory(for: FluidAudioParakeetEngine.version)) {
        self.modelDirectory = modelDirectory
    }

    func modelsArePresent() async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: Self.version)
    }

    func load(allowDownload: Bool) async throws {
        guard manager == nil else {
            return
        }

        guard allowDownload || AsrModels.modelsExist(at: modelDirectory, version: Self.version) else {
            throw ParakeetEngineError.modelsNotDownloaded
        }

        let models: AsrModels
        do {
            models =
                if allowDownload {
                    try await AsrModels.downloadAndLoad(to: modelDirectory, version: Self.version)
                } else {
                    try await AsrModels.load(from: modelDirectory, version: Self.version)
                }
        } catch {
            throw ParakeetEngineError.loadFailed("Parakeet model load failed")
        }

        let newManager = AsrManager(config: .default)
        do {
            try await newManager.initialize(models: models)
        } catch {
            throw ParakeetEngineError.loadFailed("Parakeet model initialization failed")
        }
        manager = newManager
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let manager else {
            throw ParakeetEngineError.modelsNotDownloaded
        }

        do {
            let result = try await manager.transcribe(samples)
            return result.text
        } catch {
            throw ParakeetEngineError.transcriptionFailed("Parakeet transcription failed")
        }
    }
}
