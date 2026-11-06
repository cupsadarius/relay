import Foundation

/// Writes the selected Whisper model. `@MainActor` because production writes through
/// `SettingsController`, Relay's single settings writer.
typealias WhisperModelSelectionWriter = @MainActor @Sendable (WhisperModelID?) -> Void

enum WhisperModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
}

/// `SpeechModelManaging` for the Whisper backend: catalog metadata, on-disk presence through
/// `WhisperModelStore`, and unloading through `WhisperRuntime` before a removal or switch.
struct WhisperModelManager: SpeechModelManaging {
    let backendID = BackendID.whisper.rawValue

    private let store: WhisperModelStore
    private let runtime: WhisperRuntime
    private let selectedModel: WhisperModelSelection
    private let setSelectedModel: WhisperModelSelectionWriter

    /// - Parameters:
    ///   - store: owns presence/download/remove of verified local model folders.
    ///   - runtime: owns the single loaded Whisper inference context; consulted for
    ///     unload-before-remove only, never for download or presence.
    ///   - selectedModel: synchronously reads the currently-selected model id, or `nil`.
    ///   - setSelectedModel: writes the currently-selected model id (or clears it, given `nil`).
    init(
        store: WhisperModelStore,
        runtime: WhisperRuntime,
        selectedModel: @escaping WhisperModelSelection,
        setSelectedModel: @escaping WhisperModelSelectionWriter
    ) {
        self.store = store
        self.runtime = runtime
        self.selectedModel = selectedModel
        self.setSelectedModel = setSelectedModel
    }

    /// All 11 models, in catalog order, each with `installState` from the store and `isSelected`
    /// from the selection seam. The two are independent: a model can be downloaded without being
    /// selected, or selected without being downloaded (see `WhisperModelManagerTests
    /// .testDownloadedAndSelectedAreIndependent`).
    func models() async -> [SpeechModelStatus] {
        let selected = selectedModel()
        return WhisperModelID.allCases.map { id in
            SpeechModelStatus(
                descriptor: Self.descriptor(for: id),
                capabilities: [.download, .select, .remove],
                installState: store.presence(of: id) ? .downloaded : .notDownloaded,
                isSelected: selected == id
            )
        }
    }

    /// Delegates straight to `WhisperModelStore.download`. Never selects or loads the model as a
    /// side effect -- downloading and selecting are independent user actions.
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let modelID = try Self.modelID(for: id)
        try await store.download(modelID, progress: progress)
    }

    /// Invalidates presence first so no new activation can start, then unloads the runtime
    /// (even mid-activation or mid-switch), then deletes the files. A later download repairs a partial removal.
    func removeModel(_ id: String) async throws {
        let modelID = try Self.modelID(for: id)
        store.invalidatePresence(of: modelID)
        await runtime.unload(ifInvolving: modelID)
        try await store.remove(modelID)
    }

    /// Updates the selection only; selecting a model that is not downloaded is valid.
    func selectModel(_ id: String) async throws {
        let modelID = try Self.modelID(for: id)
        await setSelectedModel(modelID)
    }

    private static func descriptor(for id: WhisperModelID) -> SpeechModelDescriptor {
        let whisperDescriptor = WhisperModelCatalog.descriptor(for: id)
        return SpeechModelDescriptor(
            id: whisperDescriptor.id.rawValue,
            displayName: whisperDescriptor.displayName,
            detail: whisperDescriptor.englishOnly ? "English only" : "Multilingual"
        )
    }

    private static func modelID(for rawValue: String) throws -> WhisperModelID {
        guard let id = WhisperModelID(rawValue: rawValue) else {
            throw WhisperModelManagerError.unknownModel(rawValue)
        }
        return id
    }
}
