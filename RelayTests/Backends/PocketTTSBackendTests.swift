import FluidAudio
import XCTest

@testable import Relay

@MainActor
final class PocketTTSBackendTests: XCTestCase {
    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = false
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = await backend.availability()

        XCTAssertEqual(fake.loadCalls, 0, "availability() must never load the model")
    }

    func testMakeAudioSourceLazilyLoadsWithoutAllowingDownload() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(fake.loadCalls, 1)
        XCTAssertEqual(fake.downloadCalls, 0)
    }

    func testMakeAudioSourceUsesPocketVoiceFromOptions() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init(voiceByBackend: [.pocketTTS: "alba"]))

        XCTAssertEqual(fake.synthesizeCalls.last?.voice, "alba")
    }

    func testMakeAudioSourceFallsBackToDefaultVoiceWhenNoneConfigured() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(fake.synthesizeCalls.last?.voice, PocketTtsConstants.defaultVoice)
    }

    func testMakeAudioSourceIgnoresAppleAndKokoroVoiceIdentifiers() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(
            text: "hello",
            options: .init(
                voiceByBackend: [
                    .appleTTS: "com.apple.voice.compact.en-US.Samantha",
                    .kokoro: "af_bella",
                    .pocketTTS: "alba",
                ]
            )
        )

        XCTAssertEqual(fake.synthesizeCalls.last?.voice, "alba")
    }

    func testMakeAudioSourceIgnoresTheSharedRateSlider() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init(rate: 0.1))
        _ = try await backend.makeAudioSource(text: "hello", options: .init(rate: 1.0))

        XCTAssertEqual(fake.synthesizeCalls.map(\.text), ["hello", "hello"])
    }

    func testMakeAudioSourceProducesTheSessionStreamFramesAtThePocketSampleRate() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        fake.synthesizeStreamFrames = [[1, 2, 3], [4, 5, 6]]
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        let source = try await backend.makeAudioSource(text: "hello", options: .init())
        var frames: [TTSAudioFrame] = []
        while let frame = try await source.next() { frames.append(frame) }

        XCTAssertEqual(frames.map(\.samples), [[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(
            frames.first?.format,
            TTSAudioFormat(sampleRate: Double(PocketTtsConstants.audioSampleRate), channelCount: 1)
        )
    }

    func testMakeAudioSourceWithEmptyTextDoesNotCrash() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(text: "", options: .init())

        XCTAssertEqual(fake.synthesizeCalls.last?.text, "")
    }

    func testMakeAudioSourceMapsModelNotDownloadedToFallbackWorthyError() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = false
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected modelNotDownloaded")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .modelNotDownloaded)
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testMakeAudioSourceMapsLoadFailureToFallbackWorthyError() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        fake.loadError = FakePocketTTSError.boom
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected initializationFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .initializationFailed("PocketTTS model load failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testMakeAudioSourceMapsSynthesisFailureToFallbackWorthyError() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        fake.synthesizeError = FakePocketTTSError.boom
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected inferenceFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .inferenceFailed("PocketTTS synthesis failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testMakeAudioSourceRethrowsCancellationErrorFromLoadWithoutRemapping() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        fake.loadError = CancellationError()
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected - must not be remapped to SpeechBackendError
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testMakeAudioSourceRethrowsCancellationErrorFromSynthesisWithoutRemapping() async {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        fake.synthesizeError = CancellationError()
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected - must not be remapped to SpeechBackendError
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testSecondMakeAudioSourceDoesNotTriggerASecondModelLoad() async throws {
        let fake = FakePocketTTS()
        fake.modelsPresent = true
        let backend = PocketTTSBackend(model: .pocketTTS(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init())
        _ = try await backend.makeAudioSource(text: "world", options: .init())

        XCTAssertEqual(fake.loadCalls, 1, "A second makeAudioSource must not reload an already-loaded model")
    }
}

private enum FakePocketTTSError: Error {
    case boom
}

/// Both the loader and the session it loads.
@MainActor
private final class FakePocketTTS: PocketTTSModelLoading, PocketTTSModelSession {
    var modelsPresent = false
    var loadError: Error?
    /// Thrown from `synthesizeStream` itself, never from inside the returned stream.
    var synthesizeError: Error?
    /// Canned frames the returned stream yields, in order, before finishing.
    var synthesizeStreamFrames: [[Float]] = []
    private(set) var loadCalls = 0
    private(set) var downloadCalls = 0
    private(set) var synthesizeCalls: [(text: String, voice: String)] = []

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func loadLocal() async throws -> any PocketTTSModelSession {
        loadCalls += 1
        if let loadError {
            throw loadError
        }
        return self
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession {
        downloadCalls += 1
        return self
    }

    func removeModels() async throws {}

    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        synthesizeCalls.append((text, voice))
        if let synthesizeError {
            throw synthesizeError
        }
        let frames = synthesizeStreamFrames
        return AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}
