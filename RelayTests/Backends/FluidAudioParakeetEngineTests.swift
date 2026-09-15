import XCTest
@testable import Relay

/// Exercises `FluidAudioParakeetEngine`'s own loading logic - single-flighting concurrent loads,
/// caching a positive local validation, retrying after a failure, and zero-padding short audio -
/// through an injected `ParakeetModelLoading` fake, since the real FluidAudio types can't be
/// constructed without downloaded model weights.
final class FluidAudioParakeetEngineTests: XCTestCase {
    func testLoadThrowsModelsNotDownloadedWhenLocalValidationFailsAndNeverCallsLoad() async {
        let loader = FakeModelLoader()
        await loader.setIsValid(false)
        let engine = makeEngine(loader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected modelsNotDownloaded")
        } catch {
            XCTAssertEqual(error as? ParakeetEngineError, .modelsNotDownloaded)
        }

        let loadCallCount = await loader.loadCallCount
        XCTAssertEqual(loadCallCount, 0, "Must never call the loader's load() without local validation")
    }

    func testLoadSucceedsAndTranscribeUsesTheLoadedSession() async throws {
        let loader = FakeModelLoader()
        await loader.setIsValid(true)
        let engine = makeEngine(loader: loader)

        try await engine.load(allowDownload: false)
        let text = try await engine.transcribe(samples: Array(repeating: Float(0.1), count: 16_000))

        XCTAssertEqual(text, "engine-result")
        let loadCallCount = await loader.loadCallCount
        XCTAssertEqual(loadCallCount, 1)
    }

    func testTranscribePadsShortSamplesUpToTheMinimumLength() async throws {
        let loader = FakeModelLoader()
        await loader.setIsValid(true)
        let engine = makeEngine(loader: loader)
        try await engine.load(allowDownload: false)

        _ = try await engine.transcribe(samples: [0.1, 0.2, 0.3])

        guard let receivedSamples = await loader.lastSessionReceivedSamples() else {
            XCTFail("Expected the loaded session to have received samples")
            return
        }
        XCTAssertEqual(receivedSamples.count, 16_000)
        XCTAssertEqual(Array(receivedSamples.prefix(3)), [0.1, 0.2, 0.3])
        XCTAssertEqual(Array(receivedSamples.suffix(4)), [0, 0, 0, 0])
    }

    func testTranscribeDoesNotPadSamplesAtOrAboveTheMinimumLength() async throws {
        let loader = FakeModelLoader()
        await loader.setIsValid(true)
        let engine = makeEngine(loader: loader)
        try await engine.load(allowDownload: false)
        let samples = Array(repeating: Float(0.5), count: 16_000)

        _ = try await engine.transcribe(samples: samples)

        let receivedSamples = await loader.lastSessionReceivedSamples()
        XCTAssertEqual(receivedSamples?.count, 16_000)
    }

    func testConcurrentLoadsShareASingleUnderlyingLoad() async throws {
        let loader = FakeModelLoader()
        await loader.setIsValid(true)
        await loader.setShouldGateLoad(true)
        let engine = makeEngine(loader: loader)

        let task1 = Task { try await engine.load(allowDownload: false) }
        let task2 = Task { try await engine.load(allowDownload: false) }

        // Give both tasks every opportunity to reach the loader before we inspect call counts;
        // a buggy (non-single-flighted) implementation would call load() a second time here.
        while await loader.loadCallCount < 1 {
            await Task.yield()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        let callCountBeforeGateOpens = await loader.loadCallCount

        await loader.openGate()
        try await task1.value
        try await task2.value

        XCTAssertEqual(callCountBeforeGateOpens, 1, "A second concurrent load must not reach the loader while the first is in flight")
        let finalCallCount = await loader.loadCallCount
        XCTAssertEqual(finalCallCount, 1, "Two concurrent loads must only invoke the underlying loader once")
    }

    func testFailedLoadCanBeRetried() async throws {
        let loader = FakeModelLoader()
        await loader.setIsValid(true)
        await loader.setLoadError(FakeLoaderError.boom)
        let engine = makeEngine(loader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected a load failure")
        } catch {
            XCTAssertEqual(error as? ParakeetEngineError, .loadFailed("Parakeet model load failed"))
        }

        await loader.setLoadError(nil)
        try await engine.load(allowDownload: false)

        let text = try await engine.transcribe(samples: Array(repeating: Float(0.1), count: 16_000))
        XCTAssertEqual(text, "engine-result")
        let loadCallCount = await loader.loadCallCount
        XCTAssertEqual(loadCallCount, 2, "The retry must reach the loader again after the first failure")
    }

    func testIsModelValidIsOnlyConsultedOnceAcrossRepeatedLoadAttempts() async throws {
        let loader = FakeModelLoader()
        await loader.setIsValid(true)
        let engine = makeEngine(loader: loader)

        try await engine.load(allowDownload: false)
        try await engine.load(allowDownload: false)
        try await engine.load(allowDownload: false)

        let validationCalls = await loader.isModelValidCallCount
        XCTAssertEqual(validationCalls, 1, "A positive validation result should be cached for the engine's lifetime")
        let loadCallCount = await loader.loadCallCount
        XCTAssertEqual(loadCallCount, 1, "Once loaded, further load() calls must be no-ops")
    }

    func testModelsArePresentNeverConsultsTheLoader() async {
        let loader = FakeModelLoader()
        let engine = makeEngine(loader: loader)

        _ = await engine.modelsArePresent()

        let validationCalls = await loader.isModelValidCallCount
        XCTAssertEqual(validationCalls, 0, "modelsArePresent() checks disk presence directly, never through the loader")
    }

    func testAllowDownloadTrueCallsDownloadAndLoadAndForwardsProgress() async throws {
        let loader = FakeModelLoader()
        let engine = makeEngine(loader: loader)
        let box = ProgressBox()

        try await engine.load(allowDownload: true, progress: { box.values.append($0) })

        let downloadCallCount = await loader.downloadCallCount
        XCTAssertEqual(downloadCallCount, 1)
        XCTAssertEqual(box.values, [1.0])
        let validationCalls = await loader.isModelValidCallCount
        XCTAssertEqual(validationCalls, 0, "allowDownload: true must skip local validation entirely")
    }

    private func makeEngine(loader: FakeModelLoader) -> FluidAudioParakeetEngine {
        FluidAudioParakeetEngine(
            modelDirectory: URL(fileURLWithPath: "/tmp/relay-parakeet-engine-tests-unused"),
            modelLoader: loader
        )
    }
}

private enum FakeLoaderError: Error, Equatable {
    case boom
}

private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

private actor FakeSession: ParakeetModelSession {
    let text: String
    private(set) var receivedSamples: [Float]?

    init(text: String) {
        self.text = text
    }

    func transcribe(samples: [Float]) async throws -> String {
        receivedSamples = samples
        return text
    }
}

private actor FakeModelLoader: ParakeetModelLoading {
    private var isValid = true
    private var loadError: Error?
    private var shouldGateLoad = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private(set) var isModelValidCallCount = 0
    private(set) var loadCallCount = 0
    private(set) var downloadCallCount = 0
    private var lastSession: FakeSession?

    func setIsValid(_ value: Bool) {
        isValid = value
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

    func lastSessionReceivedSamples() async -> [Float]? {
        await lastSession?.receivedSamples
    }

    func isModelValid() async throws -> Bool {
        isModelValidCallCount += 1
        return isValid
    }

    func load() async throws -> any ParakeetModelSession {
        loadCallCount += 1

        if shouldGateLoad {
            await withCheckedContinuation { continuation in
                gateContinuation = continuation
            }
        }

        if let loadError {
            throw loadError
        }

        let session = FakeSession(text: "engine-result")
        lastSession = session
        return session
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        downloadCallCount += 1
        progress(1.0)

        if let loadError {
            throw loadError
        }

        let session = FakeSession(text: "downloaded-result")
        lastSession = session
        return session
    }
}
