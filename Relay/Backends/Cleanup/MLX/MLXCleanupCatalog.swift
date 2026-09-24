import Foundation

/// Pinned Qwen3 MLX snapshots (spec §13.2). Values taken from the Hugging Face API on 2026-09-24.
enum MLXCleanupCatalog {
    /// Models the Settings UI offers. Spike S3 decision A keeps both.
    static let offered: [CleanupModelID] = [.qwen3_0_6b, .qwen3_1_7b]

    static let allowlist: Set<String> = [
        "config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json",
        "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt",
    ]
    static let requiredFiles: Set<String> = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
    static let tokenizerSHA256 = "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"

    static func snapshot(for id: CleanupModelID) -> PinnedSnapshot? {
        switch id {
        case .appleSystem:
            nil
        case .qwen3_0_6b:
            PinnedSnapshot(
                repo: "mlx-community/Qwen3-0.6B-4bit",
                revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
                allowlist: allowlist,
                requiredFiles: requiredFiles,
                pinnedSHA256: [
                    "model.safetensors": "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2",
                    "tokenizer.json": tokenizerSHA256,
                ]
            )
        case .qwen3_1_7b:
            PinnedSnapshot(
                repo: "mlx-community/Qwen3-1.7B-4bit",
                revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
                allowlist: allowlist,
                requiredFiles: requiredFiles,
                pinnedSHA256: [
                    "model.safetensors": "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f",
                    "tokenizer.json": tokenizerSHA256,
                ]
            )
        }
    }

    static func siblingPrefix(for id: CleanupModelID) -> String { "\(id.rawValue)@" }

    static func directoryName(for id: CleanupModelID) -> String {
        siblingPrefix(for: id) + (snapshot(for: id)?.revision ?? "none")
    }
}

/// `VerifiedModelStore` keyed by `CleanupModelID`, at `sharedModelsDirectory()/MLX/<id>@<revision>/`.
struct MLXCleanupModelStore: Sendable {
    private let store: VerifiedModelStore
    private let snapshot: @Sendable (CleanupModelID) -> PinnedSnapshot?

    init(
        root: URL,
        downloader: any SnapshotDownloading = PinnedSnapshotDownloader(),
        snapshot: @escaping @Sendable (CleanupModelID) -> PinnedSnapshot? = MLXCleanupCatalog.snapshot(for:)
    ) {
        store = VerifiedModelStore(root: root, downloader: downloader)
        self.snapshot = snapshot
    }

    func directory(for id: CleanupModelID) -> URL { store.directory(named: name(for: id)) }
    func presence(of id: CleanupModelID) -> Bool { id.isMLX && store.presence(of: name(for: id)) }
    func invalidatePresence(of id: CleanupModelID) { store.invalidatePresence(of: name(for: id)) }
    func remove(_ id: CleanupModelID) async throws { try await store.remove(name(for: id)) }

    func download(_ id: CleanupModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let snapshot = snapshot(id) else { throw MLXCleanupRuntimeError.notDownloaded }
        try await store.download(snapshot, as: name(for: id), siblingPrefix: MLXCleanupCatalog.siblingPrefix(for: id), progress: progress)
    }

    private func name(for id: CleanupModelID) -> String {
        MLXCleanupCatalog.siblingPrefix(for: id) + (snapshot(id)?.revision ?? "none")
    }
}
