import Foundation

/// Errors `ParakeetModelManager` throws. `unknownModel` covers any id that is not a
/// `ParakeetModelID`; `removeNotSupported` is returned by `removeModel`.
enum ParakeetModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    case removeNotSupported
}

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

/// The two-model `SpeechModelManaging` implementation for Relay's Parakeet backend. Wraps the
/// same `ParakeetEngine` seam `ParakeetBackend` uses, one engine per model, so tests fake the
/// engines and never construct FluidAudio/CoreML types.
struct ParakeetModelManager: SpeechModelManaging {
    let backendID = BackendID.parakeet.rawValue

    private let engines: ParakeetEngines
    private let selectedModel: ParakeetModelSelection
    private let setSelectedModel: ParakeetModelSelectionWriter

    init(
        engines: ParakeetEngines,
        selectedModel: @escaping ParakeetModelSelection,
        setSelectedModel: @escaping ParakeetModelSelectionWriter
    ) {
        self.engines = engines
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
                    installState: await engines[model].modelsArePresent() ? .downloaded : .notDownloaded,
                    isSelected: model == selected
                ))
        }
        return statuses
    }

    /// Downloads and loads the named model. Never selects it.
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let model = try Self.model(for: id)
        try await engines[model].load(allowDownload: true, progress: progress)
    }

    /// Persists the selection, then warms the model in the background when it is on disk.
    func selectModel(_ id: String) async throws {
        let model = try Self.model(for: id)
        await setSelectedModel(model)
        let engine = engines[model]
        Task { await engine.prewarmIfPresent() }
    }

    /// Parakeet has no remove path: `ParakeetEngine` exposes no delete. Validates `id` first, so
    /// an unknown id still reports `unknownModel`.
    func removeModel(_ id: String) async throws {
        _ = try Self.model(for: id)
        throw ParakeetModelManagerError.removeNotSupported
    }

    /// Loads the selected model at launch when it is on disk. Never downloads.
    func prewarmSelected() async {
        await engines[selectedModel() ?? .default].prewarmIfPresent()
    }

    private static func model(for id: String) throws -> ParakeetModelID {
        guard let model = ParakeetModelID(rawValue: id) else {
            throw ParakeetModelManagerError.unknownModel(id)
        }
        return model
    }
}
