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
        let data = try await engine.synthesize(text: "hello", voice: "alba")

        XCTAssertEqual(data, Data("hello".utf8))
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

        _ = try await engine.synthesize(text: "hello world", voice: "alba")

        let received = await loader.lastSessionReceivedArgs()
        XCTAssertEqual(received?.0, "hello world")
        XCTAssertEqual(received?.1, "alba")
    }

    func testSynthesizeBeforeLoadThrowsSynthesisFailed() async {
        let loader = FakePocketTTSModelLoader()
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        do {
            _ = try await engine.synthesize(text: "hi", voice: "alba")
            XCTFail("Expected synthesisFailed")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .synthesisFailed)
        }
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
            // The engine forwards the source's stream error as-is rather than remapping it, so
            // the router-facing `synthesize(text:voice:)` remains the only error-mapping seam.
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

    func testConcurrentLocalLoadsShareASingleUnderlyingLoad() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        await loader.setShouldGateLoad(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

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
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        await loader.setLoadError(FakeLoaderError.boom)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected a load failure")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .loadFailed)
        }

        await loader.setLoadError(nil)
        try await engine.load(allowDownload: false)

        let data = try await engine.synthesize(text: "hi", voice: "alba")
        XCTAssertEqual(data, Data("hi".utf8))
        let presentCalls = await loader.modelsArePresentCallCount
        XCTAssertEqual(presentCalls, 2, "A failed load must not cache a positive presence result, so the retry re-checks it")
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 2, "The retry must reach the loader again after the first failure")
    }

    func testPresenceCheckIsCachedAcrossRepeatedSuccessfulLocalLoads() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        try await engine.load(allowDownload: false)
        try await engine.load(allowDownload: false)
        try await engine.load(allowDownload: false)

        let presentCalls = await loader.modelsArePresentCallCount
        XCTAssertEqual(presentCalls, 1, "A positive presence result should be cached for the engine's lifetime")
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 1, "Once loaded, further load() calls must be no-ops")
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
        let modelsDirectory = tempDirectory.appendingPathComponent("Models").appendingPathComponent("pocket-tts")
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
}

private enum FakeLoaderError: Error, Equatable {
    case boom
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

    func synthesize(text: String, voice: String) async throws -> Data {
        received = (text, voice)
        return Data(text.utf8)
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
    private var shouldGateLoad = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
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

    func setShouldGateLoad(_ value: Bool) {
        shouldGateLoad = value
    }

    func openGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func lastSessionReceivedArgs() async -> (String, String)? {
        await lastSession?.received
    }

    func lastSessionStreamFrames() async -> [[Float]] {
        await lastSession?.streamFrames ?? []
    }

    func setStreamError(_ error: Error?) async {
        await lastSession?.setStreamError(error)
    }

    func modelsArePresent() async -> Bool {
        modelsArePresentCallCount += 1
        return present
    }

    func loadLocal() async throws -> any PocketTTSModelSession {
        loadLocalCallCount += 1

        if shouldGateLoad {
            await withCheckedContinuation { continuation in
                gateContinuation = continuation
            }
        }

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
