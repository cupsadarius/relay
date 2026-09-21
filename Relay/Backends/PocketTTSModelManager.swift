import Foundation

enum PocketTTSModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    case removeNotSupported
}

/// One-model `SpeechModelManaging` facade for Relay's PocketTTS backend.
struct PocketTTSModelManager: SpeechModelManaging {
    static let modelID = "pocket-tts-v2.1-en"
    let backendID = "pocket-tts"

    private let engine: any PocketTTSEngine

    init(engine: any PocketTTSEngine = FluidAudioPocketTTSEngine()) {
        self.engine = engine
    }

    func models() async -> [SpeechModelStatus] {
        let present = await engine.modelsArePresent()
        return [
            SpeechModelStatus(
                descriptor: Self.descriptor,
                installState: present ? .downloaded : .notDownloaded,
                isSelected: true,
                isLoaded: false
            )
        ]
    }

    func downloadModel(
        _ id: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.validate(id)
        try await engine.load(allowDownload: true, progress: progress)
    }

    func selectModel(_ id: String) async throws {
        try Self.validate(id)
    }

    func removeModel(_ id: String) async throws {
        try Self.validate(id)
        throw PocketTTSModelManagerError.removeNotSupported
    }

    private static let descriptor = SpeechModelDescriptor(
        id: modelID,
        displayName: "PocketTTS v2.1",
        detail: "English",
        approximateDownloadBytes: nil
    )

    private static func validate(_ id: String) throws {
        guard id == modelID else {
            throw PocketTTSModelManagerError.unknownModel(id)
        }
    }
}
