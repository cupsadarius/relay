import FluidAudio
import XCTest
@testable import Relay

/// Exercises `FluidAudioPocketTTSEngine`'s own loading logic - single-flighting concurrent loads,
/// caching a positive local presence check, retrying after a failure, and refusing to load
/// without a download when the model is absent - through an injected `PocketTTSModelLoading`
/// fake, since the real FluidAudio types can't be constructed without downloaded model weights. A
/// separate regression test below exercises the real, hand-rolled presence check against a
/// temporary directory to guard against a naive "does the cache directory exist" check.
final class FluidAudioPocketTTSEngineTests: XCTestCase {
    func testEngineRemovalReleasesSessionAndInvalidatesPresenceCache() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)

        try await engine.removeModels()

        do {
            _ = try await engine.synthesizeStream(text: "hello", voice: "alba")
            XCTFail("Expected released session")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .synthesisFailed)
        }
        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected presence to be rechecked")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .modelsNotDownloaded)
        }
    }

    func testRemoveModelsDeletesOnlyVersionedEnglishDirectoryAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let english = root.appendingPathComponent("Models/pocket-tts/v2.1/english")
        let siblingLanguage = root.appendingPathComponent("Models/pocket-tts/v2.1/spanish")
        let unrelated = root.appendingPathComponent("Models/other-provider")
        for directory in [english, siblingLanguage, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = FluidAudioPocketTTSModelLoader(cacheDirectory: root)

        try await loader.removeModels()
        try await loader.removeModels()

        XCTAssertFalse(FileManager.default.fileExists(atPath: english.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingLanguage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLoadThrowsModelsNotDownloadedWhenNotPresentAndNeverDownloads() async {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(false)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected modelsNotDownloaded")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .modelsNotDownloaded)
        }

        let downloadCalls = await loader.downloadCallCount
        XCTAssertEqual(downloadCalls, 0, "Must never call the loader's downloadAndLoad() without allowing a download")
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 0, "Must never call the loader's loadLocal() without local presence")
    }

    func testLoadWithPresentModelsLoadsLocallyAndSynthesizeUsesTheLoadedSession() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        try await engine.load(allowDownload: false)
        let stream = try await engine.synthesizeStream(text: "hello", voice: "alba")
        var frames: [[Float]] = []
        for try await frame in stream { frames.append(frame) }
        let expected = await loader.lastSessionStreamFrames()
        XCTAssertEqual(frames, expected)
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 1)
        let downloadCalls = await loader.downloadCallCount
        XCTAssertEqual(downloadCalls, 0)
    }

    func testSynthesizeForwardsTextAndVoiceToTheLoadedSession() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)

        _ = try await engine.synthesizeStream(text: "hello world", voice: "alba")

        let received = await loader.lastSessionReceivedArgs()
        XCTAssertEqual(received?.0, "hello world")
        XCTAssertEqual(received?.1, "alba")
    }

    func testSynthesizeStreamBeforeLoadThrowsSynthesisFailed() async {
        let loader = FakePocketTTSModelLoader()
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        do {
            _ = try await engine.synthesizeStream(text: "hi", voice: "alba")
            XCTFail("Expected synthesisFailed")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .synthesisFailed)
        }
    }

    func testSynthesizeStreamAfterLoadYieldsCannedFramesInOrderAndFinishes() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)

        let stream = try await engine.synthesizeStream(text: "hello", voice: "alba")

        var received: [[Float]] = []
        for try await frame in stream {
            received.append(frame)
        }

        let expected = await loader.lastSessionStreamFrames()
        XCTAssertEqual(received, expected)
        XCTAssertFalse(received.isEmpty)
    }

    func testSynthesizeStreamPropagatesASourceError() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)
        try await engine.load(allowDownload: false)
        await loader.setStreamError(FakeLoaderError.boom)

        let stream = try await engine.synthesizeStream(text: "hello", voice: "alba")

        do {
            for try await _ in stream {}
            XCTFail("Expected the stream to throw")
        } catch {
            // The engine forwards the source's stream error as-is rather than remapping it.
            XCTAssertEqual(error as? FakeLoaderError, .boom)
        }
    }

    func testModelsArePresentDelegatesToLoaderWithoutLoading() async {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        let present = await engine.modelsArePresent()

        XCTAssertTrue(present)
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 0, "modelsArePresent() must never trigger a load")
    }

    func testLoaderFailureMapsToLoadFailed() async {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        await loader.setLoadError(FakeLoaderError.boom)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected loadFailed")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .loadFailed)
        }
    }

    func testAllowDownloadTrueSkipsThePresenceCheckAndForwardsProgress() async throws {
        let loader = FakePocketTTSModelLoader()
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)
        let box = ProgressBox()

        try await engine.load(allowDownload: true, progress: { box.values.append($0) })

        let downloadCalls = await loader.downloadCallCount
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(box.values, [1.0])
        let presentCalls = await loader.modelsArePresentCallCount
        XCTAssertEqual(presentCalls, 0, "allowDownload: true must skip the local presence check entirely")
    }

    /// Regression test for the "cache directory always exists" trap: a naive presence check based
    /// on the outer cache directory's existence would always report `true`. This exercises the
    /// real, hand-rolled `FluidAudioPocketTTSModelLoader.modelsArePresent()` against a throwaway
    /// temp directory (never the real cache) that has the outer directory but no
    /// `Models/pocket-tts/*` model bundles.
    func testModelsArePresentReturnsFalseWhenOnlyTheOuterDirectoryExistsButNoModelBundlesDo() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioPocketTTSModelLoader(cacheDirectory: tempDirectory)
        let present = await loader.modelsArePresent()

        XCTAssertFalse(present, "An outer directory with no model bundles must not be reported as present")
    }

    func testModelsArePresentReturnsTrueOnlyWhenEveryRequiredModelExists() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Matches `FluidAudioPocketTTSModelLoader.modelsDirectory`: FluidAudio 0.15 nests each
        // language pack under a versioned subdirectory (`v2.1/<language>/`), computed here the
        // same way rather than hardcoded so this test tracks the loader instead of drifting from
        // it.
        let modelsDirectory = tempDirectory
            .appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory)
            .appendingPathComponent(Repo.pocketTts.folderName)
            .appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioPocketTTSModelLoader(cacheDirectory: tempDirectory)
        let requiredModels = Array(ModelNames.PocketTTS.requiredModels)

        // Only the first required model exists: still not present.
        try FileManager.default.createDirectory(
            at: modelsDirectory.appendingPathComponent(requiredModels[0]),
            withIntermediateDirectories: true
        )
        var present = await loader.modelsArePresent()
        XCTAssertFalse(present, "Must require every model bundle, not just one")

        // Every required model exists: present.
        for model in requiredModels {
            try FileManager.default.createDirectory(
                at: modelsDirectory.appendingPathComponent(model),
                withIntermediateDirectories: true
            )
        }
        present = await loader.modelsArePresent()
        XCTAssertTrue(present)
    }

    func testFrameStreamAdapterPullsUpstreamOnlyAsTheConsumerAsks() async throws {
        let pulls = PullCounter()
        let upstream = AsyncThrowingStream<Int, Error>(unfolding: {
            let pull = await pulls.increment()
            return pull <= 5 ? pull : nil
        })
        let mapped = PocketTTSFrameStream.samples(from: upstream) { [Float($0)] }

        var iterator = mapped.makeAsyncIterator()
        let first = try await iterator.next()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(first, [1])
        let pulled = await pulls.value
        XCTAssertEqual(pulled, 1, "the adapter must not drain FluidAudio's stream ahead of the consumer")
    }

    func testFrameStreamAdapterForwardsElementsThenUpstreamErrors() async {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(7)
            continuation.finish(throwing: FakeLoaderError.boom)
        }
        let mapped = PocketTTSFrameStream.samples(from: upstream) { [Float($0)] }

        var received: [[Float]] = []
        do {
            for try await samples in mapped { received.append(samples) }
            XCTFail("Expected the upstream error")
        } catch {
            XCTAssertEqual(error as? FakeLoaderError, .boom)
        }
        XCTAssertEqual(received, [[7]])
    }
}

private enum FakeLoaderError: Error, Equatable {
    case boom
}

private actor PullCounter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

private actor FakePocketTTSSession: PocketTTSModelSession {
    let text: String
    private(set) var received: (String, String)?
    let streamFrames: [[Float]] = [[1, 2, 3], [4, 5, 6]]
    private var streamError: Error?

    init(text: String) {
        self.text = text
    }

    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        received = (text, voice)
        let frames = streamFrames
        let error = streamError
        return AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish(throwing: error)
        }
    }

    func setStreamError(_ error: Error?) {
        streamError = error
    }
}

private actor FakePocketTTSModelLoader: PocketTTSModelLoading {
    private var present = false
    private var loadError: Error?
    private(set) var modelsArePresentCallCount = 0
    private(set) var loadLocalCallCount = 0
    private(set) var downloadCallCount = 0
    private var lastSession: FakePocketTTSSession?

    func setPresent(_ value: Bool) {
        present = value
    }

    func setLoadError(_ error: Error?) {
        loadError = error
    }

    func lastSessionReceivedArgs() async -> (String, String)? {
        await lastSession?.received
    }

    func lastSessionStreamFrames() async -> [[Float]] {
        lastSession?.streamFrames ?? []
    }

    func setStreamError(_ error: Error?) async {
        await lastSession?.setStreamError(error)
    }

    func modelsArePresent() async -> Bool {
        modelsArePresentCallCount += 1
        return present
    }

    func removeModels() async throws { present = false }

    func loadLocal() async throws -> any PocketTTSModelSession {
        loadLocalCallCount += 1

        if let loadError {
            throw loadError
        }

        let session = FakePocketTTSSession(text: "local-result")
        lastSession = session
        return session
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession {
        downloadCallCount += 1
        progress(1.0)

        if let loadError {
            throw loadError
        }

        let session = FakePocketTTSSession(text: "downloaded-result")
        lastSession = session
        return session
    }
}
