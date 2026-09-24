import Synchronization
import XCTest

@testable import Relay

@MainActor
final class MLXCleanupModelManagerTests: XCTestCase {
    private var root: URL!
    private let selection = LockedValue<CleanupModelID?>(nil)
    private let files = ["config.json": Data("{}".utf8), "model.safetensors": Data("w".utf8)]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        selection.withLock { $0 = nil }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> MLXCleanupModelStore {
        let files = files
        return MLXCleanupModelStore(
            root: root, downloader: FakeSnapshotDownloader(files: files),
            snapshot: { _ in
                PinnedSnapshot(repo: "org/m", revision: "r1", allowlist: Set(files.keys), requiredFiles: Set(files.keys), pinnedSHA256: [:])
            }
        )
    }

    private func makeManager(
        store: MLXCleanupModelStore? = nil,
        runtime: FakeMLXRuntime = FakeMLXRuntime(),
        log: OrderLog? = nil,
        memory: UInt64 = 16 << 30
    ) -> MLXCleanupModelManager {
        let selection = selection
        return MLXCleanupModelManager(
            store: store ?? makeStore(),
            runtime: runtime,
            selectedModel: { selection.withLock { $0 } },
            setSelectedModel: { id in
                log?.append("select \(id?.rawValue ?? "nil")")
                selection.withLock { $0 = id }
            },
            offered: [.qwen3_0_6b, .qwen3_1_7b],
            physicalMemory: memory
        )
    }

    func testListsBothModelsWithStoreStateAndGlobalSelection() async throws {
        let store = makeStore()
        try await store.download(.qwen3_0_6b) { _ in }
        selection.withLock { $0 = .qwen3_0_6b }

        let statuses = await makeManager(store: store).models()

        XCTAssertEqual(statuses.map(\.id), ["mlx.qwen3-0.6b-4bit", "mlx.qwen3-1.7b-4bit"])
        XCTAssertEqual(statuses.map(\.descriptor.displayName), ["Qwen3 0.6B", "Qwen3 1.7B"])
        XCTAssertEqual(statuses.map(\.installState), [.downloaded, .notDownloaded])
        XCTAssertEqual(statuses.map(\.isSelected), [true, false])
        XCTAssertEqual(statuses.map(\.capabilities), [[.download, .select, .remove], [.download, .select, .remove]])
        XCTAssertEqual(statuses.map(\.usability), [.usable, .usable])
    }

    func testAppleSelectionMarksNoMLXRowSelected() async {
        selection.withLock { $0 = .appleSystem }
        let statuses = await makeManager().models()
        XCTAssertEqual(statuses.map(\.isSelected), [false, false])
    }

    func testDetailTexts() async {
        let roomy = await makeManager(memory: 16 << 30).models().map(\.descriptor.detail)
        XCTAssertEqual(roomy, ["~351 MB", "~984 MB · uses ~1.5 GB memory while loaded"])
        let tight = await makeManager(memory: 8 << 30).models().map(\.descriptor.detail)
        XCTAssertEqual(tight, ["~351 MB", "~984 MB · uses ~1.5 GB memory while loaded · May slow other apps on 8 GB Macs"])
    }

    func testOnlyOfferedModelsAreListed() async {
        let selection = selection
        let manager = MLXCleanupModelManager(
            store: makeStore(), runtime: FakeMLXRuntime(), selectedModel: { selection.withLock { $0 } }, setSelectedModel: { _ in },
            offered: [.qwen3_0_6b], physicalMemory: 16 << 30
        )
        let ids = await manager.models().map(\.id)
        XCTAssertEqual(ids, ["mlx.qwen3-0.6b-4bit"])
        do {
            try await manager.downloadModel("mlx.qwen3-1.7b-4bit") { _ in }
            XCTFail("expected unknownModel")
        } catch {
            XCTAssertEqual(error as? CleanupModelManagerError, .unknownModel("mlx.qwen3-1.7b-4bit"))
        }
    }

    func testDownloadNeverSelectsOrLoads() async throws {
        let runtime = FakeMLXRuntime()
        let store = makeStore()
        try await makeManager(store: store, runtime: runtime).downloadModel("mlx.qwen3-0.6b-4bit") { _ in }
        XCTAssertTrue(store.presence(of: .qwen3_0_6b))
        XCTAssertNil(selection.withLock { $0 })
        let loads = await runtime.ensureLoadedCalls
        XCTAssertEqual(loads, [])
    }

    func testSelectRequiresADownload() async throws {
        let store = makeStore()
        let manager = makeManager(store: store)
        do {
            try await manager.selectModel("mlx.qwen3-0.6b-4bit")
            XCTFail("expected notDownloaded")
        } catch {
            XCTAssertEqual(error as? CleanupModelManagerError, .notDownloaded)
        }
        try await store.download(.qwen3_0_6b) { _ in }
        try await manager.selectModel("mlx.qwen3-0.6b-4bit")
        XCTAssertEqual(selection.withLock { $0 }, .qwen3_0_6b)
    }

    func testRemoveInvalidatesUnloadsDeletesThenClearsTheSelection() async throws {
        let log = OrderLog()
        let runtime = FakeMLXRuntime(log: log)
        let store = makeStore()
        try await store.download(.qwen3_0_6b) { _ in }
        selection.withLock { $0 = .qwen3_0_6b }

        try await makeManager(store: store, runtime: runtime, log: log).removeModel("mlx.qwen3-0.6b-4bit")

        XCTAssertEqual(log.values, ["unloadIfInvolving mlx.qwen3-0.6b-4bit", "select nil"])
        XCTAssertFalse(store.presence(of: .qwen3_0_6b))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: .qwen3_0_6b).path))
    }

    func testRemovingAnUnselectedModelKeepsTheSelection() async throws {
        let store = makeStore()
        try await store.download(.qwen3_1_7b) { _ in }
        selection.withLock { $0 = .appleSystem }

        try await makeManager(store: store).removeModel("mlx.qwen3-1.7b-4bit")

        XCTAssertEqual(selection.withLock { $0 }, .appleSystem)
    }

    func testRejectsNonMLXIDs() async {
        for id in ["apple.system-language-model", "nope"] {
            do {
                try await makeManager().selectModel(id)
                XCTFail("expected unknownModel")
            } catch {
                XCTAssertEqual(error as? CleanupModelManagerError, .unknownModel(id))
            }
        }
    }
}
