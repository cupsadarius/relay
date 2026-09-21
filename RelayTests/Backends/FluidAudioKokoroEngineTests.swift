import FluidAudio
import XCTest
@testable import Relay

/// Exercises `FluidAudioKokoroEngine`'s own loading logic - single-flighting concurrent loads,
/// caching a positive local presence check, retrying after a failure, and refusing to load
/// without a download when the model is absent - through an injected `KokoroModelLoading` fake,
/// since the real FluidAudio types can't be constructed without downloaded model weights. A
/// separate regression test below exercises the real, hand-rolled presence check against a
/// temporary directory to guard against `TtsModels.cacheDirectoryURL()`'s auto-created-directory
/// trap.
final class FluidAudioKokoroEngineTests: XCTestCase {
    func testEngineRemovalReleasesSessionAndInvalidatesPresenceCache() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)

        try await engine.removeModels()

        do {
            _ = try await engine.synthesize(text: "hello", voice: "af_heart", speed: 1)
            XCTFail("Expected released session")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .synthesisFailed)
        }
        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected presence to be rechecked")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .modelsNotDownloaded)
        }
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

    func testLoadThrowsModelsNotDownloadedWhenNotPresentAndNeverDownloads() async {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(false)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected modelsNotDownloaded")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .modelsNotDownloaded)
        }

        let downloadCalls = await loader.downloadCallCount
        XCTAssertEqual(downloadCalls, 0, "Must never call the loader's downloadAndLoad() without allowing a download")
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 0, "Must never call the loader's loadLocal() without local presence")
    }

    func testLoadWithPresentModelsLoadsLocallyAndSynthesizeUsesTheLoadedSession() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        try await engine.load(allowDownload: false)
        let data = try await engine.synthesize(text: "hello", voice: "af_heart", speed: 1.0)

        XCTAssertEqual(data, Data("hello".utf8))
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 1)
        let downloadCalls = await loader.downloadCallCount
        XCTAssertEqual(downloadCalls, 0)
    }

    func testSynthesizeForwardsTextVoiceAndSpeedToTheLoadedSession() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)

        _ = try await engine.synthesize(text: "hello world", voice: "am_adam", speed: 1.5)

        let received = await loader.lastSessionReceivedArgs()
        XCTAssertEqual(received?.0, "hello world")
        XCTAssertEqual(received?.1, "am_adam")
        XCTAssertEqual(received?.2, 1.5)
    }

    func testSynthesizeBeforeLoadThrowsSynthesisFailed() async {
        let loader = FakeKokoroModelLoader()
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        do {
            _ = try await engine.synthesize(text: "hi", voice: "af_heart", speed: 1.0)
            XCTFail("Expected synthesisFailed")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .synthesisFailed)
        }
    }

    func testSynthesizeMapsPhonemeSequenceTooLongToTextTooLong() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)
        await loader.setLastSessionSynthesizeError(KokoroAneError.phonemeSequenceTooLong(600))

        do {
            _ = try await engine.synthesize(text: String(repeating: "word ", count: 200), voice: "af_heart", speed: 1.0)
            XCTFail("Expected textTooLong")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .textTooLong)
        }
    }

    func testModelsArePresentDelegatesToLoaderWithoutLoading() async {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        let present = await engine.modelsArePresent()

        XCTAssertTrue(present)
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 0, "modelsArePresent() must never trigger a load")
    }

    func testConcurrentLocalLoadsShareASingleUnderlyingLoad() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        await loader.setShouldGateLoad(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        let task1 = Task { try await engine.load(allowDownload: false) }
        let task2 = Task { try await engine.load(allowDownload: false) }

        // Give both tasks every opportunity to reach the loader before we inspect call counts;
        // a buggy (non-single-flighted) implementation would call loadLocal() a second time here.
        while await loader.loadLocalCallCount < 1 {
            await Task.yield()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        let callCountBeforeGateOpens = await loader.loadLocalCallCount

        await loader.openGate()
        try await task1.value
        try await task2.value

        XCTAssertEqual(callCountBeforeGateOpens, 1, "A second concurrent load must not reach the loader while the first is in flight")
        let finalCallCount = await loader.loadLocalCallCount
        XCTAssertEqual(finalCallCount, 1, "Two concurrent loads must only invoke the underlying loader once")
    }

    func testFailedLocalLoadDoesNotCacheAFalsePresentSoARetryReconsultsTheLoader() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        await loader.setLoadError(FakeLoaderError.boom)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected a load failure")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .loadFailed)
        }

        await loader.setLoadError(nil)
        try await engine.load(allowDownload: false)

        let data = try await engine.synthesize(text: "hi", voice: "af_heart", speed: 1.0)
        XCTAssertEqual(data, Data("hi".utf8))
        let presentCalls = await loader.modelsArePresentCallCount
        XCTAssertEqual(presentCalls, 2, "A failed load must not cache a positive presence result, so the retry re-checks it")
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 2, "The retry must reach the loader again after the first failure")
    }

    func testPresenceCheckIsCachedAcrossRepeatedSuccessfulLocalLoads() async throws {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        try await engine.load(allowDownload: false)
        try await engine.load(allowDownload: false)
        try await engine.load(allowDownload: false)

        let presentCalls = await loader.modelsArePresentCallCount
        XCTAssertEqual(presentCalls, 1, "A positive presence result should be cached for the engine's lifetime")
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 1, "Once loaded, further load() calls must be no-ops")
    }

    func testAllowDownloadTrueSkipsThePresenceCheckAndForwardsProgress() async throws {
        let loader = FakeKokoroModelLoader()
        let engine = FluidAudioKokoroEngine(modelLoader: loader)
        let box = ProgressBox()

        try await engine.load(allowDownload: true, progress: { box.values.append($0) })

        let downloadCalls = await loader.downloadCallCount
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(box.values, [1.0])
        let presentCalls = await loader.modelsArePresentCallCount
        XCTAssertEqual(presentCalls, 0, "allowDownload: true must skip the local presence check entirely")
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

    private func makeEngine(loader: FakeKokoroModelLoader) -> FluidAudioKokoroEngine {
        FluidAudioKokoroEngine(modelLoader: loader)
    }
}

private enum FakeLoaderError: Error, Equatable {
    case boom
}

private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

private actor FakeKokoroSession: KokoroModelSession {
    let text: String
    private(set) var received: (String, String, Float)?
    private var synthesizeError: Error?

    init(text: String) {
        self.text = text
    }

    func setSynthesizeError(_ error: Error?) {
        synthesizeError = error
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        received = (text, voice, speed)
        if let synthesizeError {
            throw synthesizeError
        }
        return Data(text.utf8)
    }
}

private actor FakeKokoroModelLoader: KokoroModelLoading {
    private var present = false
    private var loadError: Error?
    private var shouldGateLoad = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private(set) var modelsArePresentCallCount = 0
    private(set) var loadLocalCallCount = 0
    private(set) var downloadCallCount = 0
    private var lastSession: FakeKokoroSession?

    func setPresent(_ value: Bool) {
        present = value
    }

    func setLoadError(_ error: Error?) {
        loadError = error
    }

    func setShouldGateLoad(_ value: Bool) {
        shouldGateLoad = value
    }

    func openGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func lastSessionReceivedArgs() async -> (String, String, Float)? {
        await lastSession?.received
    }

    func setLastSessionSynthesizeError(_ error: Error?) async {
        await lastSession?.setSynthesizeError(error)
    }

    func modelsArePresent() async -> Bool {
        modelsArePresentCallCount += 1
        return present
    }

    func removeModels() async throws { present = false }

    func loadLocal() async throws -> any KokoroModelSession {
        loadLocalCallCount += 1

        if shouldGateLoad {
            await withCheckedContinuation { continuation in
                gateContinuation = continuation
            }
        }

        if let loadError {
            throw loadError
        }

        let session = FakeKokoroSession(text: "local-result")
        lastSession = session
        return session
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession {
        downloadCallCount += 1
        progress(1.0)

        if let loadError {
            throw loadError
        }

        let session = FakeKokoroSession(text: "downloaded-result")
        lastSession = session
        return session
    }
}
