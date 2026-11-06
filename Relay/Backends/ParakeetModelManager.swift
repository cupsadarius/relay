import Foundation

extension ParakeetModelID {
    fileprivate var descriptor: SpeechModelDescriptor {
        switch self {
        case .unifiedEnglish:
            SpeechModelDescriptor(id: rawValue, displayName: "Parakeet Unified (English)", detail: "English · punctuation")
        case .v2:
            SpeechModelDescriptor(id: rawValue, displayName: "Parakeet v2", detail: "English only")
        }
    }
}

/// The two-model `SpeechModelManaging` implementation for Relay's Parakeet backend. Uses the same
/// `ParakeetModels` as `ParakeetBackend`.
struct ParakeetModelManager: SpeechModelManaging {
    let backendID = BackendID.parakeet

    private let models: ParakeetModels
    private let selectedModel: ParakeetModelSelection
    private let setSelectedModel: ParakeetModelSelectionWriter

    init(
        models: ParakeetModels,
        selectedModel: @escaping ParakeetModelSelection,
        setSelectedModel: @escaping ParakeetModelSelectionWriter
    ) {
        self.models = models
        self.selectedModel = selectedModel
        self.setSelectedModel = setSelectedModel
    }

    func models() async -> [SpeechModelStatus] {
        let selected = selectedModel() ?? .default
        var statuses: [SpeechModelStatus] = []
        for model in ParakeetModelID.allCases {
            statuses.append(
                SpeechModelStatus(
                    descriptor: model.descriptor,
                    capabilities: [.download, .select],
                    installState: await models[model].modelsArePresent() ? .downloaded : .notDownloaded,
                    isSelected: model == selected
                ))
        }
        return statuses
    }

    /// Downloads and loads the named model. Never selects it.
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let model = try Self.model(for: id)
        try await models[model].load(allowDownload: true, progress: progress)
    }

    /// Persists the selection, then warms the model in the background when it is on disk.
    func selectModel(_ id: String) async throws {
        let model = try Self.model(for: id)
        await setSelectedModel(model)
        let localModel = models[model]
        Task { await localModel.prewarmIfPresent() }
    }

    /// Validates `id` first, so an unknown id still reports `unknownModel`.
    func removeModel(_ id: String) async throws {
        try await models[Self.model(for: id)].remove()
    }

    /// Loads the selected model at launch when it is on disk. Never downloads.
    func prewarmSelected() async {
        await models[selectedModel() ?? .default].prewarmIfPresent()
    }

    private static func model(for id: String) throws -> ParakeetModelID {
        guard let model = ParakeetModelID(rawValue: id) else {
            throw SpeechModelManagerError.unknownModel(id)
        }
        return model
    }
}
