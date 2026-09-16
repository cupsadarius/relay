import XCTest
@testable import Relay

@MainActor
final class ParakeetBackendTests: XCTestCase {
    func testIdentifiesAsParakeet() {
        let backend = ParakeetBackend(engine: FakeParakeetEngine())

        XCTAssertEqual(backend.id, "parakeet")
        XCTAssertEqual(backend.displayName, "Parakeet")
    }

    func testCapabilitiesIncludeFullyOffline() {
        let backend = ParakeetBackend(engine: FakeParakeetEngine())

        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
    }

    func testCapabilitiesDoNotAdvertiseMultilingual() {
        let backend = ParakeetBackend(engine: FakeParakeetEngine())

        XCTAssertFalse(backend.capabilities.contains(.multilingual))
        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = false
        let backend = ParakeetBackend(engine: engine)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        let backend = ParakeetBackend(engine: engine)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        let backend = ParakeetBackend(engine: engine)

        _ = await backend.availability()

        XCTAssertTrue(engine.loadCalls.isEmpty, "availability() must never load the engine")
    }

    func testTranscribeForwardsSamplesUnchangedAndWrapsResultInTranscript() async throws {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.transcriptionResult = "hello world"
        let backend = ParakeetBackend(engine: engine)
        let samples: [Float] = [0.1, -0.2, 0.3]

        let transcript = try await backend.transcribe(
            audio: AudioInput(samples: samples, sampleRate: 16_000),
            options: .init()
        )

        XCTAssertEqual(transcript, Transcript(text: "hello world", backendID: "parakeet"))
        XCTAssertEqual(engine.receivedSamples, samples)
    }

    func testTranscribeThrowsNoUsableAudioForEmptySamples() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected noUsableAudio")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .noUsableAudio)
        }
        XCTAssertTrue(engine.loadCalls.isEmpty, "Should not attempt to load the engine for unusable audio")
    }

    func testTranscribeThrowsInvalidInputForWrongSampleRate() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 44_100),
                options: .init()
            )
            XCTFail("Expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
        XCTAssertTrue(engine.loadCalls.isEmpty, "Should not attempt to load the engine for the wrong sample rate")
    }

    func testPrepareTriggersEngineLoadWithoutAllowingDownload() async throws {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        let backend = ParakeetBackend(engine: engine)

        try await backend.prepare()

        XCTAssertEqual(engine.loadCalls, [false])
    }

    func testTranscribeLazilyLoadsWhenNotYetPrepared() async throws {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.transcriptionResult = "lazy"
        let backend = ParakeetBackend(engine: engine)

        _ = try await backend.transcribe(
            audio: AudioInput(samples: [0.1], sampleRate: 16_000),
            options: .init()
        )

        XCTAssertEqual(engine.loadCalls, [false])
    }

    func testSecondTranscribeDoesNotTriggerASecondEngineLoad() async throws {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.transcriptionResult = "hi"
        let backend = ParakeetBackend(engine: engine)

        _ = try await backend.transcribe(audio: AudioInput(samples: [0.1], sampleRate: 16_000), options: .init())
        _ = try await backend.transcribe(audio: AudioInput(samples: [0.1], sampleRate: 16_000), options: .init())

        XCTAssertEqual(engine.loadCalls, [false], "A second transcribe must not reload an already-loaded engine")
    }

    func testTranscribeMapsModelsNotDownloadedLoadFailureToModelNotDownloaded() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.loadError = ParakeetEngineError.modelsNotDownloaded
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected modelNotDownloaded")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .modelNotDownloaded)
        }
    }

    func testTranscribeMapsLoadFailedToInitializationFailed() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.loadError = ParakeetEngineError.loadFailed("boom")
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("boom"))
        }
    }

    func testTranscribeSucceedsAfterAPreviousLoadFailure() async throws {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.loadError = ParakeetEngineError.loadFailed("boom")
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(audio: AudioInput(samples: [0.1], sampleRate: 16_000), options: .init())
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("boom"))
        }

        engine.loadError = nil
        engine.transcriptionResult = "recovered"
        let transcript = try await backend.transcribe(
            audio: AudioInput(samples: [0.1], sampleRate: 16_000),
            options: .init()
        )

        XCTAssertEqual(transcript, Transcript(text: "recovered", backendID: "parakeet"))
        XCTAssertEqual(engine.loadCalls, [false, false], "A failed load must not block a later retry")
    }

    func testPrepareMapsLoadFailedToInitializationFailed() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.loadError = ParakeetEngineError.loadFailed("boom")
        let backend = ParakeetBackend(engine: engine)

        do {
            try await backend.prepare()
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("boom"))
        }
    }

    func testTranscribeMapsEngineTranscriptionFailureToInferenceFailed() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.transcribeError = ParakeetEngineError.transcriptionFailed("bad audio")
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected inferenceFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .inferenceFailed("bad audio"))
        }
    }

    func testTranscribeMapsNotLoadedToInitializationFailed() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.transcribeError = ParakeetEngineError.notLoaded
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("Parakeet model is not loaded"))
        }
    }

    func testTranscribePreservesCancellationFromEngineTranscription() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.transcribeError = CancellationError()
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation remains distinguishable from inference failure.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testTranscribePreservesCancellationFromLoad() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.loadError = CancellationError()
        let backend = ParakeetBackend(engine: engine)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation remains distinguishable from initialization failure.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testPreparePreservesCancellationFromLoad() async {
        let engine = FakeParakeetEngine()
        engine.modelsPresent = true
        engine.loadError = CancellationError()
        let backend = ParakeetBackend(engine: engine)

        do {
            try await backend.prepare()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testDownloadModelsAllowsDownload() async throws {
        let engine = FakeParakeetEngine()
        let backend = ParakeetBackend(engine: engine)

        try await backend.downloadModels()

        XCTAssertEqual(engine.loadCalls, [true])
    }

    func testDownloadModelsForwardsProgressToCaller() async throws {
        let engine = FakeParakeetEngine()
        engine.progressToReport = [0.25, 0.75, 1.0]
        let backend = ParakeetBackend(engine: engine)
        let box = ProgressReportBox()

        try await backend.downloadModels(progress: { box.values.append($0) })

        XCTAssertEqual(box.values, [0.25, 0.75, 1.0])
    }

    func testDownloadModelsMapsFailureToInitializationFailed() async {
        let engine = FakeParakeetEngine()
        engine.loadError = ParakeetEngineError.loadFailed("network down")
        let backend = ParakeetBackend(engine: engine)

        do {
            try await backend.downloadModels()
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("network down"))
        }
    }

    func testDownloadModelsPreservesCancellation() async {
        let engine = FakeParakeetEngine()
        engine.loadError = CancellationError()
        let backend = ParakeetBackend(engine: engine)

        do {
            try await backend.downloadModels()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }
}

/// Accumulates progress fractions reported from a `@Sendable` download-progress closure. The
/// engine under test only ever calls the closure synchronously from a single caller, so the
/// lack of internal locking is safe here even though the type opts out of Sendable checking.
private final class ProgressReportBox: @unchecked Sendable {
    var values: [Double] = []
}

/// Mirrors the real `ParakeetEngine` contract's idempotency guarantee ("Idempotent once loaded"):
/// once a `load` call succeeds, later calls no longer append to `loadCalls`. A load that throws
/// leaves the engine unloaded so the next call retries for real - this is what lets
/// `testTranscribeSucceedsAfterAPreviousLoadFailure` and `testSecondTranscribeDoesNotTrigger...`
/// exercise both halves of that contract from `ParakeetBackend`'s side.
@MainActor
private final class FakeParakeetEngine: ParakeetEngine {
    var modelsPresent = false
    var transcriptionResult = ""
    var loadError: Error?
    var transcribeError: Error?
    var progressToReport: [Double] = []
    private(set) var loadCalls: [Bool] = []
    private(set) var receivedSamples: [Float] = []
    private var isLoaded = false

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isLoaded else { return }
        loadCalls.append(allowDownload)
        for fraction in progressToReport {
            progress(fraction)
        }
        if let loadError {
            throw loadError
        }
        isLoaded = true
    }

    func transcribe(samples: [Float]) async throws -> String {
        receivedSamples = samples
        if let transcribeError {
            throw transcribeError
        }
        return transcriptionResult
    }
}
