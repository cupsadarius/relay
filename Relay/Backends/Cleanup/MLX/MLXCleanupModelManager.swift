import Foundation

/// `SpeechModelManaging` for the Qwen3 MLX cleanup models (spec §13.5). Differs from
/// `WhisperModelManager` in two ways on purpose: selecting requires a download, and removing the
/// selected model clears the selection (after the files are gone).
struct MLXCleanupModelManager: SpeechModelManaging {
    let backendID = BackendID.mlxCleanup.rawValue

    private let store: MLXCleanupModelStore
    private let runtime: any MLXCleanupRuntimeServing
    private let selectedModel: CleanupModelSelection
    private let setSelectedModel: CleanupModelSelectionWriter
    private let offered: [CleanupModelID]
    private let physicalMemory: UInt64

    init(
        store: MLXCleanupModelStore,
        runtime: any MLXCleanupRuntimeServing,
        selectedModel: @escaping CleanupModelSelection,
        setSelectedModel: @escaping CleanupModelSelectionWriter,
        offered: [CleanupModelID] = MLXCleanupCatalog.offered,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.store = store
        self.runtime = runtime
        self.selectedModel = selectedModel
        self.setSelectedModel = setSelectedModel
        self.offered = offered
        self.physicalMemory = physicalMemory
    }

    func models() async -> [SpeechModelStatus] {
        let selected = selectedModel()
        return offered.map { id in
            SpeechModelStatus(
                descriptor: SpeechModelDescriptor(id: id.rawValue, displayName: id.displayName, detail: Self.detail(for: id, physicalMemory: physicalMemory)),
                capabilities: [.download, .select, .remove],
                installState: store.presence(of: id) ? .downloaded : .notDownloaded,
                isSelected: selected == id
            )
        }
    }

    /// Never selects or loads.
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await store.download(modelID(id), progress: progress)
    }

    func selectModel(_ id: String) async throws {
        let modelID = try modelID(id)
        guard store.presence(of: modelID) else { throw CleanupModelManagerError.notDownloaded }
        await setSelectedModel(modelID)
    }

    /// 1. invalidate presence, 2. unload if involved, 3. delete files, 4. only then clear the
    /// selection if it was this model. If step 3 throws, the selection is kept.
    func removeModel(_ id: String) async throws {
        let modelID = try modelID(id)
        store.invalidatePresence(of: modelID)
        await runtime.unload(ifInvolving: modelID)
        try await store.remove(modelID)
        if selectedModel() == modelID { await setSelectedModel(nil) }
    }

    /// Launch sweep: deletes the downloaded files of every MLX model that is no longer offered
    /// (Qwen3 0.6B), through the store's `remove`. The selection is left alone: a retired id already
    /// reads as no selection. A failed removal is retried at the next launch.
    func sweepUnofferedModels() async {
        for id in CleanupModelID.allCases where id.isMLX && !offered.contains(id) && store.presence(of: id) {
            store.invalidatePresence(of: id)
            await runtime.unload(ifInvolving: id)
            try? await store.remove(id)
        }
    }

    static func detail(for id: CleanupModelID, physicalMemory: UInt64) -> String {
        switch id {
        case .qwen3_0_6b:
            return "~351 MB"
        case .qwen3_1_7b:
            let base = "~984 MB · uses ~1.5 GB memory while loaded"
            return physicalMemory <= 8 << 30 ? base + " · May slow other apps on 8 GB Macs" : base
        case .appleSystem:
            return "Built in"
        }
    }

    private func modelID(_ rawValue: String) throws -> CleanupModelID {
        guard let id = CleanupModelID(rawValue: rawValue), id.isMLX, offered.contains(id) else {
            throw CleanupModelManagerError.unknownModel(rawValue)
        }
        return id
    }
}
