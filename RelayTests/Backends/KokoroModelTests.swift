import FluidAudio
import XCTest

@testable import Relay

/// Kokoro-specific model facts: the hand-rolled presence check against real temporary
/// directories, file removal, and synthesis error mapping. Load rules live in
/// `ModelSessionLoaderTests`; the backend path lives in `KokoroTTSBackendTests`.
final class KokoroModelTests: XCTestCase {
    func testRemoveDropsTheSessionAndRechecksPresence() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let model = KokoroModel.kokoro(loader: loader)
        try await model.load()

        try await model.remove()

        do {
            try await model.load()
            XCTFail("Expected presence to be rechecked")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .modelsNotDownloaded)
        }
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 1)
    }

    func testRemoveThrowsWhenFilesRemain() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        await loader.setRemoveKeepsFiles(true)
        let model = KokoroModel.kokoro(loader: loader)

        do {
            try await model.remove()
            XCTFail("Expected loadFailed")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .loadFailed)
        }
    }

    func testSynthesisErrorMappingKeepsOnlyLengthFailuresAndCancellation() {
        XCTAssertEqual(KokoroEngineError.synthesis(KokoroAneError.phonemeSequenceTooLong(600)) as? KokoroEngineError, .textTooLong)
        XCTAssertEqual(KokoroEngineError.synthesis(FakeLoaderError.boom) as? KokoroEngineError, .synthesisFailed)
        XCTAssertTrue(KokoroEngineError.synthesis(CancellationError()) is CancellationError)
    }

    func testRemoveModelsDeletesOnlyANEAndG2PDirectoriesAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ane = root.appendingPathComponent("kokoro-82m-coreml/ANE")
        let g2p = root.appendingPathComponent("kokoro")
        let unrelated = root.appendingPathComponent("other-provider")
        for directory in [ane, g2p, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = FluidAudioKokoroModelLoader(cacheDirectory: root)

        try await loader.removeModels()
        try await loader.removeModels()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ane.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: g2p.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// Regression test for the "cache directory always exists" trap: `TtsModels.cacheDirectoryURL()`
    /// creates `~/.cache/fluidaudio` if it's missing, so a naive presence check based on that
    /// directory's existence would always report `true`. This exercises the real, hand-rolled
    /// `FluidAudioKokoroModelLoader.modelsArePresent()` against a throwaway temp directory (never
    /// the real cache) that has the outer directory but no `Models/kokoro/*.mlmodelc` bundles.
    func testModelsArePresentReturnsFalseWhenOnlyTheOuterDirectoryExistsButNoModelBundlesDo() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioKokoroModelLoader(cacheDirectory: tempDirectory)
        let present = await loader.modelsArePresent()

        XCTAssertFalse(present, "An outer directory with no model bundles must not be reported as present")
    }

    func testModelsArePresentReturnsTrueOnlyWhenEveryVariantBundleExists() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Matches `FluidAudioKokoroModelLoader.modelsDirectory`: cacheDirectory/<repo.folderName>,
        // where the English KokoroAne variant's folder name is "kokoro-82m-coreml/ANE".
        let modelsDirectory = tempDirectory.appendingPathComponent("kokoro-82m-coreml").appendingPathComponent("ANE")
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioKokoroModelLoader(cacheDirectory: tempDirectory)
        let fileNames = Array(ModelNames.KokoroAne.requiredModels)

        // The shared G2P assets are present from the start here: this test is only about the ANE
        // bundle-by-bundle behavior. See the dedicated G2P tests below for the widened gate.
        try createG2PAssets(under: tempDirectory)

        // Only the first bundle exists: still not present.
        try FileManager.default.createDirectory(
            at: modelsDirectory.appendingPathComponent(fileNames[0]),
            withIntermediateDirectories: true
        )
        var present = await loader.modelsArePresent()
        XCTAssertFalse(present, "Must require every variant bundle, not just one")

        // All bundles exist: present.
        for fileName in fileNames {
            try FileManager.default.createDirectory(
                at: modelsDirectory.appendingPathComponent(fileName),
                withIntermediateDirectories: true
            )
        }
        present = await loader.modelsArePresent()
        XCTAssertTrue(present)
    }

    /// Regression test for the gate widening: `KokoroAneManager.initialize()` (English variant)
    /// also hard-downloads the shared G2P CoreML assets (`ModelNames.G2P.requiredModels`) into
    /// `<cacheDirectory>/kokoro/*` - a different folder than the ANE chain's
    /// `<cacheDirectory>/kokoro-82m-coreml/ANE/*`. A gate that only checked the ANE folder would
    /// report `true` on a partial cache (ANE present, G2P fetch previously failed) and let a
    /// `load(allowDownload: false)` reach the network via `initialize()`.
    func testModelsArePresentReturnsFalseWhenAneModelsPresentButG2PAssetsAreMissing() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try createAneModels(under: tempDirectory)
        // Deliberately no G2P assets created.

        let loader = FluidAudioKokoroModelLoader(cacheDirectory: tempDirectory)
        let present = await loader.modelsArePresent()

        XCTAssertFalse(present, "ANE models alone must not satisfy the gate when the shared G2P assets are absent")
    }

    /// Mirror of the above: G2P assets present but the ANE chain missing must also fail the gate.
    func testModelsArePresentReturnsFalseWhenG2PAssetsPresentButAneModelsAreMissing() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try createG2PAssets(under: tempDirectory)
        // Deliberately no ANE models created.

        let loader = FluidAudioKokoroModelLoader(cacheDirectory: tempDirectory)
        let present = await loader.modelsArePresent()

        XCTAssertFalse(present, "G2P assets alone must not satisfy the gate when the ANE chain is absent")
    }

    /// Only once both the ANE chain and the shared G2P assets are on disk does the gate report
    /// present - the positive counterpart to the two tests above.
    func testModelsArePresentReturnsTrueOnlyWhenBothAneModelsAndG2PAssetsArePresent() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioKokoroModelLoader(cacheDirectory: tempDirectory)

        try createAneModels(under: tempDirectory)
        var present = await loader.modelsArePresent()
        XCTAssertFalse(present, "Must still be false with only the ANE chain present")

        try createG2PAssets(under: tempDirectory)
        present = await loader.modelsArePresent()
        XCTAssertTrue(present, "Must be true once both the ANE chain and the shared G2P assets are present")
    }

    /// Creates every file `ModelNames.KokoroAne.requiredModels` names under
    /// `<cacheDirectory>/kokoro-82m-coreml/ANE/`, matching
    /// `FluidAudioKokoroModelLoader.modelsDirectory` for the English variant.
    private func createAneModels(under cacheDirectory: URL) throws {
        let modelsDirectory = cacheDirectory.appendingPathComponent("kokoro-82m-coreml").appendingPathComponent("ANE")
        for fileName in ModelNames.KokoroAne.requiredModels {
            try FileManager.default.createDirectory(
                at: modelsDirectory.appendingPathComponent(fileName),
                withIntermediateDirectories: true
            )
        }
    }

    /// Creates every file `ModelNames.G2P.requiredModels` names under `<cacheDirectory>/kokoro/`,
    /// matching `FluidAudioKokoroModelLoader.g2pDirectory` (`Repo.kokoro.folderName == "kokoro"`).
    /// Mirrors the mixed file/directory handling of `FluidAudioKokoroModelLoader.allFilesExist`:
    /// every required name is created as a directory here (as the existing ANE fixtures already
    /// do for `vocab.json`/`af_heart.bin`) since `FileManager.fileExists(atPath:)` does not
    /// distinguish files from directories.
    private func createG2PAssets(under cacheDirectory: URL) throws {
        let g2pDirectory = cacheDirectory.appendingPathComponent(Repo.kokoro.folderName)
        for fileName in ModelNames.G2P.requiredModels {
            try FileManager.default.createDirectory(
                at: g2pDirectory.appendingPathComponent(fileName),
                withIntermediateDirectories: true
            )
        }
    }
}

private enum FakeLoaderError: Error, Equatable {
    case boom
}

private struct FakeKokoroSession: KokoroModelSession {
    func phonemes(for text: String) async throws -> String { text }
    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        KokoroPCM(samples: [], sampleRate: 24_000)
    }
}

private actor FakeKokoroModelLoader: KokoroModelLoading {
    private var present = false
    private var removeKeepsFiles = false
    private(set) var loadLocalCallCount = 0

    func setPresent(_ value: Bool) { present = value }
    func setRemoveKeepsFiles(_ value: Bool) { removeKeepsFiles = value }
    func modelsArePresent() async -> Bool { present }
    func removeModels() async throws { present = removeKeepsFiles }

    func loadLocal() async throws -> any KokoroModelSession {
        loadLocalCallCount += 1
        return FakeKokoroSession()
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession {
        FakeKokoroSession()
    }
}
