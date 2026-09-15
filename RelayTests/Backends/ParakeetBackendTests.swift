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

    func testDownloadModelsAllowsDownload() async throws {
        let engine = FakeParakeetEngine()
        let backend = ParakeetBackend(engine: engine)

        try await backend.downloadModels()

        XCTAssertEqual(engine.loadCalls, [true])
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
}

@MainActor
private final class FakeParakeetEngine: ParakeetEngine {
    var modelsPresent = false
    var transcriptionResult = ""
    var loadError: Error?
    var transcribeError: Error?
    private(set) var loadCalls: [Bool] = []
    private(set) var receivedSamples: [Float] = []

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func load(allowDownload: Bool) async throws {
        loadCalls.append(allowDownload)
        if let loadError {
            throw loadError
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        receivedSamples = samples
        if let transcribeError {
            throw transcribeError
        }
        return transcriptionResult
    }
}
