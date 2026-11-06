import Foundation

/// `SpeechModelManaging` for a backend with exactly one model, which is always selected.
struct SingleModelManager: SpeechModelManaging {
    let backendID: BackendID
    let descriptor: SpeechModelDescriptor
    let capabilities: SpeechModelCapabilities
    let isPresent: @Sendable () async -> Bool
    let download: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    let remove: @Sendable () async throws -> Void

    func models() async -> [SpeechModelStatus] {
        [
            SpeechModelStatus(
                descriptor: descriptor,
                capabilities: capabilities,
                installState: await isPresent() ? .downloaded : .notDownloaded,
                isSelected: true
            )
        ]
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try validate(id)
        try await download(progress)
    }

    func selectModel(_ id: String) async throws {
        try validate(id)
    }

    func removeModel(_ id: String) async throws {
        try validate(id)
        try await remove()
    }

    private func validate(_ id: String) throws {
        guard id == descriptor.id else { throw SpeechModelManagerError.unknownModel(id) }
    }
}

extension SingleModelManager {
    /// Voice selection is separate from model selection.
    static func kokoro(model: KokoroModel) -> Self {
        SingleModelManager(
            backendID: .kokoro,
            descriptor: SpeechModelDescriptor(id: "kokoro-82m-ane-en", displayName: "Kokoro 82M ANE", detail: "English"),
            capabilities: [.download, .select, .remove],
            isPresent: { await model.modelsArePresent() },
            download: { progress in try await model.load(allowDownload: true, progress: progress) },
            remove: { try await model.remove() }
        )
    }

    static func pocketTTS(engine: any PocketTTSEngine) -> Self {
        SingleModelManager(
            backendID: .pocketTTS,
            descriptor: SpeechModelDescriptor(id: "pocket-tts-v2.1-en", displayName: "PocketTTS v2.1", detail: "English"),
            capabilities: [.download, .select, .remove],
            isPresent: { await engine.modelsArePresent() },
            download: { progress in try await engine.load(allowDownload: true, progress: progress) },
            remove: { try await engine.removeModels() }
        )
    }

    /// Apple's recognizer ships with macOS, so there is nothing to download or remove.
    static let appleSpeech = SingleModelManager(
        backendID: .appleSpeech,
        descriptor: SpeechModelDescriptor(id: "apple-on-device", displayName: "On-device", detail: nil),
        capabilities: [.select],
        isPresent: { true },
        download: { _ in },
        remove: { throw SpeechModelManagerError.removeNotSupported }
    )
}
