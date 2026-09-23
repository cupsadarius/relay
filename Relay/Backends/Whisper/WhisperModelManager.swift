import Foundation

/// Reads which Whisper model is currently selected, synchronously. Reused from
/// `WhisperBackend`'s own seam of the same shape (`WhisperBackend.swift`) so both types agree on
/// how selection is read without either one owning storage for it.
///
/// `WhisperModelSelectionWriter` is the write half `WhisperModelManager` additionally needs:
/// `selectModel` writes through it, and in production it (like the getter) is backed by
/// `AppSettings`' persisted selection, wired up in `RelayRuntime.makeProduction()`. In tests it is
/// a fake closure pair the test owns directly.
///
/// `@MainActor`, unlike the getter: production's writer (`RelayRuntime.makeProduction()`) needs
/// to reach `AppModel.setSelectedSpeechModel` -- the app's sole settings writer, MainActor-
/// isolated -- so the write can go through `AppModel.updateSettings` and land on disk, rather
/// than a production service mutating `AppSettings`/`SettingsBox` directly. `selectModel` is only
/// ever reached through `AppModel.selectSpeechModel` (already MainActor), so awaiting a
/// MainActor-isolated closure from there is a same-actor hop, not a real suspension.
typealias WhisperModelSelectionWriter = @MainActor @Sendable (WhisperModelID?) -> Void

/// Errors `WhisperModelManager` itself throws for a model-id string that doesn't map onto any
/// `WhisperModelID`. Model-id validation lives here (the one place `SpeechModelManaging`'s
/// stringly-typed ids meet the concrete `WhisperModelID` enum), not in `AppSettings` or any
/// caller.
enum WhisperModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
}

/// The 11-model `SpeechModelManaging` implementation for Relay's Whisper backend. Composes:
/// - `WhisperModelCatalog` for static per-model metadata (via `WhisperModelID.allCases`).
/// - `WhisperModelStore` for on-disk presence/download/remove.
/// - `WhisperRuntime` for which model (if any) is currently loaded, and to unload it when a
///   removal or model switch requires that.
/// - A selection getter/setter closure pair for the currently-selected model id, decoupled from
///   `AppSettings` (see `WhisperModelSelection`/`WhisperModelSelectionWriter`).
///
/// A plain `struct`: every stored seam is itself `Sendable` (`WhisperModelStore` is a value type,
/// `WhisperRuntime` is an actor, the closures are `@Sendable`), so `WhisperModelManager` needs no
/// isolation of its own -- unlike `WhisperBackend`, which is an actor only because it forwards to
/// `WhisperRuntime` without adding any state of its own either, but is written as an actor to
/// match `SpeechToTextBackend`'s existing backends. Here there is no such precedent to match, and
/// a struct keeps this the simplest thing that satisfies `Sendable`.
struct WhisperModelManager: SpeechModelManaging {
    let backendID = "whisper"

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

    /// Deletes a downloaded model's files. If `id` is the currently-loaded model, unloads the
    /// runtime *first* (so no stale context can be left pointing at deleted files), then deletes
    /// from the store; a not-loaded model is deleted directly, without touching the runtime.
    /// Removing the selected model is allowed and leaves the selection in place, pointing at a
    /// now-absent model -- `WhisperBackend.availability()` already reports `.modelNotDownloaded`
    /// for that state, so no special-casing is needed here.
    func removeModel(_ id: String) async throws {
        let modelID = try Self.modelID(for: id)
        if await runtime.currentModelID == modelID {
            await runtime.unload()
        }
        try await store.remove(modelID)
    }

    /// Updates the selection only. Never downloads and never loads: selecting a not-downloaded
    /// id is valid (selection and installed state are independent), and it is each caller's own
    /// job (e.g. a "Download" button, or `WhisperBackend.prepare()`'s on-demand activation) to
    /// decide when a selection should actually be fetched or loaded.
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
