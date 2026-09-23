import Foundation

enum KokoroModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
}

/// One-model `SpeechModelManaging` facade for Relay's Kokoro backend.
/// Voice selection is intentionally separate from model selection.
struct KokoroModelManager: SpeechModelManaging {
    static let modelID = "kokoro-82m-ane-en"
    let backendID = "kokoro"

    private let engine: any KokoroEngine

    init(engine: any KokoroEngine) {
        self.engine = engine
    }

    func models() async -> [SpeechModelStatus] {
        let present = await engine.modelsArePresent()
        return [
            SpeechModelStatus(
                descriptor: Self.descriptor,
                capabilities: [.download, .select, .remove],
                installState: present ? .downloaded : .notDownloaded,
                isSelected: true
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
        try await engine.removeModels()
    }

    private static let descriptor = SpeechModelDescriptor(
        id: modelID,
        displayName: "Kokoro 82M ANE",
        detail: "English"
    )

    private static func validate(_ id: String) throws {
        guard id == modelID else {
            throw KokoroModelManagerError.unknownModel(id)
        }
    }
}
