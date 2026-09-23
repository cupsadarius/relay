import XCTest
@testable import Relay

/// Exercises `FluidAudioParakeetEngine`'s own loading logic - single-flighting concurrent loads,
/// caching a positive local validation, retrying after a failure, and zero-padding short audio -
/// through an injected `ParakeetModelLoading` fake, since the real FluidAudio types can't be
/// constructed without downloaded model weights.
final class FluidAudioParakeetEngineTests: XCTestCase {
    func testUsesEnglishOnlyParakeetModel() async {
        let engine = makeEngine(loader: FakeModelLoader())
        let modelDirectory = await engine.modelDirectory

        // FluidAudio 0.15's `Repo.folderName` dropped the "-coreml" suffix for repos that fall
        // through to its `default` case (via `name.replacingOccurrences(of: "-coreml", with: "")`),
        // which is where `.parakeetV2` now lands - the cache folder name changed from
        // "parakeet-tdt-0.6b-v2-coreml" (0.12.6) to "parakeet-tdt-0.6b-v2" (0.15.7). Anyone
        // upgrading with an existing download will re-download once under the new path.
        XCTAssertEqual(modelDirectory.lastPathComponent, "parakeet-tdt-0.6b-v2")
    }

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

    func testValidationErrorMapsToLoadFailedWithTheValidationLabel() async {
        let loader = FakeModelLoader()
        await loader.setValidationError(FakeLoaderError.boom)
        let engine = makeEngine(loader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected loadFailed")
        } catch {
            XCTAssertEqual(error as? ParakeetEngineError, .loadFailed("Parakeet model validation failed"))
        }
    }

    private func makeEngine(loader: FakeModelLoader) -> FluidAudioParakeetEngine {
        FluidAudioParakeetEngine(modelLoader: loader)
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
    private var validationError: Error?
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

    func setValidationError(_ error: Error?) {
        validationError = error
    }

    func lastSessionReceivedSamples() async -> [Float]? {
        await lastSession?.receivedSamples
    }

    func isModelValid() async throws -> Bool {
        isModelValidCallCount += 1
        if let validationError {
            throw validationError
        }
        return isValid
    }

    func load() async throws -> any ParakeetModelSession {
        loadCallCount += 1

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
