import XCTest

@testable import Relay

final class MLXCleanupCatalogTests: XCTestCase {
    func testPinsExactRevisionsAndHashes() throws {
        let small = try XCTUnwrap(MLXCleanupCatalog.snapshot(for: .qwen3_0_6b))
        XCTAssertEqual(small.repo, "mlx-community/Qwen3-0.6B-4bit")
        XCTAssertEqual(small.revision, "73e3e38d981303bc594367cd910ea6eb48349da8")
        XCTAssertEqual(small.pinnedSHA256["model.safetensors"], "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2")
        XCTAssertEqual(small.pinnedSHA256["tokenizer.json"], "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")

        let large = try XCTUnwrap(MLXCleanupCatalog.snapshot(for: .qwen3_1_7b))
        XCTAssertEqual(large.repo, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(large.revision, "3b1b1768f8f8cf8351c712464f906e86c2b8269e")
        XCTAssertEqual(large.pinnedSHA256["model.safetensors"], "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f")

        XCTAssertNil(MLXCleanupCatalog.snapshot(for: .appleSystem))
    }

    func testAllowlistAndRequiredFiles() throws {
        let snapshot = try XCTUnwrap(MLXCleanupCatalog.snapshot(for: .qwen3_0_6b))
        XCTAssertEqual(
            snapshot.allowlist,
            [
                "config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json",
                "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt",
            ]
        )
        XCTAssertEqual(snapshot.requiredFiles, ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        XCTAssertTrue(snapshot.revision.count == 40 && snapshot.revision.allSatisfy(\.isHexDigit))
    }

    func testDirectoryNamesCarryTheRevision() {
        XCTAssertEqual(MLXCleanupCatalog.directoryName(for: .qwen3_0_6b), "mlx.qwen3-0.6b-4bit@73e3e38d981303bc594367cd910ea6eb48349da8")
        XCTAssertEqual(MLXCleanupCatalog.siblingPrefix(for: .qwen3_1_7b), "mlx.qwen3-1.7b-4bit@")
    }

    func testStoreUsesTheSharedMLXFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "config.json": Data("{}".utf8), "model.safetensors": Data("w".utf8), "tokenizer.json": Data("t".utf8),
            "tokenizer_config.json": Data("c".utf8),
        ]
        let snapshot = PinnedSnapshot(
            repo: "org/m", revision: "r1", allowlist: Set(files.keys), requiredFiles: Set(files.keys), pinnedSHA256: [:]
        )
        let store = MLXCleanupModelStore(root: root, downloader: FakeSnapshotDownloader(files: files), snapshot: { _ in snapshot })

        try await store.download(.qwen3_0_6b) { _ in }

        XCTAssertTrue(store.presence(of: .qwen3_0_6b))
        XCTAssertFalse(store.presence(of: .qwen3_1_7b))
        XCTAssertEqual(store.directory(for: .qwen3_0_6b).lastPathComponent, "mlx.qwen3-0.6b-4bit@r1")
    }

    func testBothModelsAreOfferedAfterSpikeS3() {
        XCTAssertEqual(MLXCleanupCatalog.offered, [.qwen3_0_6b, .qwen3_1_7b])
    }
}
