import XCTest

@testable import Relay

@MainActor
final class ParakeetBackendTests: XCTestCase {
    private func makeBackend(_ fake: FakeParakeet) -> ParakeetBackend {
        let model = ParakeetModel.parakeet(loader: fake)
        return ParakeetBackend(models: ParakeetModels(unifiedEnglish: model, v2: model), selectedModel: { nil })
    }

    func testTranscribesWithTheModelOfTheSelectedId() async throws {
        let unified = FakeParakeet()
        unified.modelsPresent = true
        unified.transcriptionResult = "unified"
        let v2 = FakeParakeet()
        v2.modelsPresent = true
        v2.transcriptionResult = "v2"
        let audio = AudioInput(samples: [0.1], sampleRate: 16_000)

        func transcript(selected: ParakeetModelID?) async throws -> String {
            let backend = ParakeetBackend(
                models: ParakeetModels(unifiedEnglish: .parakeet(loader: unified), v2: .parakeet(loader: v2)),
                selectedModel: { selected }
            )
            return try await backend.transcribe(audio: audio, options: .init()).text
        }

        let none = try await transcript(selected: nil)
        let chosenV2 = try await transcript(selected: .v2)
        let chosenUnified = try await transcript(selected: .unifiedEnglish)
        XCTAssertEqual(none, "unified")
        XCTAssertEqual(chosenV2, "v2")
        XCTAssertEqual(chosenUnified, "unified")
    }

    func testAvailabilityReflectsTheSelectedModel() async {
        let unified = FakeParakeet()
        unified.modelsPresent = true
        let v2 = FakeParakeet()
        let backend = ParakeetBackend(
            models: ParakeetModels(unifiedEnglish: .parakeet(loader: unified), v2: .parakeet(loader: v2)),
            selectedModel: { .v2 }
        )

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let fake = FakeParakeet()
        fake.modelsPresent = false
        let backend = makeBackend(fake)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        let backend = makeBackend(fake)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        let backend = makeBackend(fake)

        _ = await backend.availability()

        XCTAssertEqual(fake.loadCalls, 0, "availability() must never load the model")
        XCTAssertEqual(fake.validateCalls, 0, "availability() must never validate the model files")
    }

    func testTranscribeForwardsSamplesAndWrapsResultInTranscript() async throws {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.transcriptionResult = "hello world"
        let backend = makeBackend(fake)
        let samples: [Float] = [0.1, -0.2, 0.3]

        let transcript = try await backend.transcribe(
            audio: AudioInput(samples: samples, sampleRate: 16_000),
            options: .init()
        )

        XCTAssertEqual(transcript, Transcript(text: "hello world", backendID: .parakeet))
        XCTAssertEqual(Array(fake.receivedSamples.prefix(3)), samples)
    }

    func testTranscribeThrowsNoUsableAudioForEmptySamples() async {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        let backend = makeBackend(fake)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected noUsableAudio")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .noUsableAudio)
        }
        XCTAssertEqual(fake.loadCalls, 0, "Should not attempt to load the model for unusable audio")
    }

    func testTranscribeThrowsInvalidInputForWrongSampleRate() async {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        let backend = makeBackend(fake)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 44_100),
                options: .init()
            )
            XCTFail("Expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
        XCTAssertEqual(fake.loadCalls, 0, "Should not attempt to load the model for the wrong sample rate")
    }

    func testTranscribeLazilyLoadsWhenNotYetPrepared() async throws {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.transcriptionResult = "lazy"
        let backend = makeBackend(fake)

        _ = try await backend.transcribe(
            audio: AudioInput(samples: [0.1], sampleRate: 16_000),
            options: .init()
        )

        XCTAssertEqual(fake.loadCalls, 1)
        XCTAssertEqual(fake.downloadCalls, 0)
    }

    func testSecondTranscribeDoesNotTriggerASecondModelLoad() async throws {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.transcriptionResult = "hi"
        let backend = makeBackend(fake)

        _ = try await backend.transcribe(audio: AudioInput(samples: [0.1], sampleRate: 16_000), options: .init())
        _ = try await backend.transcribe(audio: AudioInput(samples: [0.1], sampleRate: 16_000), options: .init())

        XCTAssertEqual(fake.loadCalls, 1, "A second transcribe must not reload an already-loaded model")
    }

    func testTranscribeMapsModelsNotDownloadedLoadFailureToModelNotDownloaded() async {
        let fake = FakeParakeet()
        fake.modelsValid = false
        let backend = makeBackend(fake)

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
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.loadError = FakeParakeetError.boom
        let backend = makeBackend(fake)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("Parakeet model load failed"))
        }
    }

    func testTranscribeMapsValidationFailureToInitializationFailed() async {
        let fake = FakeParakeet()
        fake.validationError = FakeParakeetError.boom
        let backend = makeBackend(fake)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("Parakeet model validation failed"))
        }
    }

    func testTranscribeSucceedsAfterAPreviousLoadFailure() async throws {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.loadError = FakeParakeetError.boom
        let backend = makeBackend(fake)

        do {
            _ = try await backend.transcribe(audio: AudioInput(samples: [0.1], sampleRate: 16_000), options: .init())
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("Parakeet model load failed"))
        }

        fake.loadError = nil
        fake.transcriptionResult = "recovered"
        let transcript = try await backend.transcribe(
            audio: AudioInput(samples: [0.1], sampleRate: 16_000),
            options: .init()
        )

        XCTAssertEqual(transcript, Transcript(text: "recovered", backendID: .parakeet))
        XCTAssertEqual(fake.loadCalls, 2, "A failed load must not block a later retry")
    }

    func testTranscribeMapsSessionTranscriptionFailureToInferenceFailed() async {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.transcribeError = FakeParakeetError.boom
        let backend = makeBackend(fake)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected inferenceFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .inferenceFailed("Parakeet transcription failed"))
        }
    }

    func testTranscribePreservesCancellationFromSessionTranscription() async {
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.transcribeError = CancellationError()
        let backend = makeBackend(fake)

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
        let fake = FakeParakeet()
        fake.modelsPresent = true
        fake.loadError = CancellationError()
        let backend = makeBackend(fake)

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

}

private enum FakeParakeetError: Error {
    case boom
}

/// Both the loader and the session it loads.
@MainActor
private final class FakeParakeet: ParakeetModelLoading, ParakeetModelSession {
    nonisolated let trailingSilenceSampleCount = 0
    var modelsPresent = false
    var modelsValid = true
    var validationError: Error?
    var transcriptionResult = ""
    var loadError: Error?
    var transcribeError: Error?
    private(set) var validateCalls = 0
    private(set) var loadCalls = 0
    private(set) var downloadCalls = 0
    private(set) var receivedSamples: [Float] = []

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func isModelValid() async throws -> Bool {
        validateCalls += 1
        if let validationError {
            throw validationError
        }
        return modelsValid
    }

    func load() async throws -> any ParakeetModelSession {
        loadCalls += 1
        if let loadError {
            throw loadError
        }
        return self
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        downloadCalls += 1
        return self
    }

    func transcribe(samples: [Float]) async throws -> String {
        receivedSamples = samples
        if let transcribeError {
            throw transcribeError
        }
        return transcriptionResult
    }
}
