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
/// `@MainActor`, unlike the getter: production's writer is `SettingsController.whisperSelectionWriter`,
/// so the write persists through Relay's single settings writer. `selectModel` is only ever
/// reached through `AppModel.selectSpeechModel` (already MainActor), so awaiting a
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

    /// Deletes a downloaded model's files, in three steps that close a TOCTOU window:
    /// 1. Invalidate presence first (delete just the `.verified` marker) -- from this point,
    ///    `store.presence(of:)` reports `false`, so no NEW caller (e.g. `WhisperBackend
    ///    .availability()`/`.transcribe`) can start a fresh activation of `id` and race the rest
    ///    of this removal for its files.
    /// 2. Unload the runtime -- so no stale context is left pointing at files about to be
    ///    deleted. `runtime.unload(ifInvolving:)`, not a plain `currentModelID == modelID` check,
    ///    covers this correctly even while `id` is mid-activation or being drained by a switch
    ///    away from it, both of which read `currentModelID` as `nil` despite the runtime still
    ///    needing `id`'s files -- that only handles callers already in flight *before* step 1;
    ///    step 1 is what stops new ones.
    /// 3. Delete the remaining files. A model the runtime has no stake in skips straight to this.
    ///
    /// If step 3 throws (e.g. the filesystem removal fails partway through) after step 1 already
    /// ran, presence was already invalidated and is not restored: `models()` reports `id` as
    /// `.notDownloaded` from that point on, same as if removal had fully succeeded. A later
    /// `downloadModel` call for `id` repairs this by re-verifying and re-promoting its files, so
    /// there is no state a caller needs to clean up by hand.
    ///
    /// Removing the selected model is allowed and leaves the selection in place, pointing at a
    /// now-absent model -- `WhisperBackend.availability()` already reports `.modelNotDownloaded`
    /// for that state, so no special-casing is needed here.
    func removeModel(_ id: String) async throws {
        let modelID = try Self.modelID(for: id)
        store.invalidatePresence(of: modelID)
        await runtime.unload(ifInvolving: modelID)
        try await store.remove(modelID)
    }

    /// Updates the selection only. Never downloads and never loads: selecting a not-downloaded
    /// id is valid (selection and installed state are independent), and it is each caller's own
    /// job (e.g. a "Download" button, or `WhisperBackend.transcribe`'s on-demand activation) to
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
