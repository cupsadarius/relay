import FluidAudio
import XCTest

@testable import Relay

@MainActor
final class KokoroTTSBackendTests: XCTestCase {
    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let fake = FakeKokoro()
        fake.modelsPresent = false
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        _ = await backend.availability()

        XCTAssertEqual(fake.loadCalls, 0, "availability() must never load the model")
    }

    func testMakeAudioSourceLazilyLoadsWithoutAllowingDownload() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(fake.loadCalls, 1)
        XCTAssertEqual(fake.downloadCalls, 0)
    }

    func testMakeAudioSourcePhonemizesTheFullText() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(fake.phonemeTextCalls, ["hello"])
    }

    func testMakeAudioSourceUsesKokoroVoiceFromOptions() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let source = try await backend.makeAudioSource(text: "hello", options: .init(voiceByBackend: [.kokoro: "am_adam"]))
        try await drain(source)

        XCTAssertEqual(fake.synthesizeCalls.last?.voice, "am_adam")
    }

    func testMakeAudioSourceFallsBackToRecommendedVoiceWhenNoneConfigured() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let source = try await backend.makeAudioSource(text: "hello", options: .init())
        try await drain(source)

        XCTAssertEqual(fake.synthesizeCalls.last?.voice, TtsConstants.recommendedVoice)
    }

    func testMakeAudioSourceIgnoresAppleVoiceIdentifier() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let source = try await backend.makeAudioSource(
            text: "hello",
            options: .init(voiceByBackend: [.appleTTS: "com.apple.voice.compact.en-US.Samantha", .kokoro: "af_bella"])
        )
        try await drain(source)

        XCTAssertEqual(fake.synthesizeCalls.last?.voice, "af_bella")
    }

    func testMakeAudioSourceMapsSharedRateDefaultToNormalKokoroSpeed() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let source = try await backend.makeAudioSource(text: "hello", options: .init(rate: 0.5))
        try await drain(source)

        XCTAssertEqual(try XCTUnwrap(fake.synthesizeCalls.last?.speed), 1.0, accuracy: 0.0001)
    }

    func testMakeAudioSourceMapsSlowestAndFastestSharedRatesProportionally() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let slow = try await backend.makeAudioSource(text: "hello", options: .init(rate: 0.1))
        try await drain(slow)
        XCTAssertEqual(try XCTUnwrap(fake.synthesizeCalls.last?.speed), 0.2, accuracy: 0.0001)

        let fast = try await backend.makeAudioSource(text: "hello", options: .init(rate: 1.0))
        try await drain(fast)
        XCTAssertEqual(try XCTUnwrap(fake.synthesizeCalls.last?.speed), 2.0, accuracy: 0.0001)
    }

    func testSpeedIsClampedToTheSupportedRange() {
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: 5), 2.0, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: -1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: .nan), 1.0, accuracy: 0.0001)
    }

    func testMakeAudioSourceWithEmptyTextDoesNotCrash() async throws {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        let source = try await backend.makeAudioSource(text: "", options: .init())
        try await drain(source)

        XCTAssertEqual(fake.phonemeTextCalls.last, "")
    }

    func testMakeAudioSourceMapsModelNotDownloadedToFallbackWorthyError() async {
        let fake = FakeKokoro()
        fake.modelsPresent = false
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

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
        let fake = FakeKokoro()
        fake.modelsPresent = true
        fake.loadError = FakeKokoroError.boom
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected initializationFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .initializationFailed("Kokoro model load failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testMakeAudioSourceMapsPhonemizationFailureToFallbackWorthyError() async {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        fake.phonemesError = KokoroEngineError.synthesisFailed
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected inferenceFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .inferenceFailed("Kokoro synthesis failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testMakeAudioSourceRethrowsCancellationErrorFromLoadWithoutRemapping() async {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        fake.loadError = CancellationError()
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected - must not be remapped to SpeechBackendError
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testMakeAudioSourceRethrowsCancellationErrorFromPhonemizationWithoutRemapping() async {
        let fake = FakeKokoro()
        fake.modelsPresent = true
        fake.phonemesError = CancellationError()
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

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
        let fake = FakeKokoro()
        fake.modelsPresent = true
        let backend = KokoroTTSBackend(model: .kokoro(loader: fake))

        _ = try await backend.makeAudioSource(text: "hello", options: .init())
        _ = try await backend.makeAudioSource(text: "world", options: .init())

        XCTAssertEqual(fake.loadCalls, 1, "A second makeAudioSource must not reload an already-loaded model")
    }

    // MARK: Helpers

    /// Pulls a source to completion so its producer runs every `synthesize(phonemes:voice:speed:)`
    /// the backend wired up (voice/speed only reach the session when the source is consumed).
    private func drain(_ source: any TTSAudioSource) async throws {
        while try await source.next() != nil {}
    }
}

private enum FakeKokoroError: Error {
    case boom
}

/// Both the loader and the session it loads.
@MainActor
private final class FakeKokoro: KokoroModelLoading, KokoroModelSession {
    var modelsPresent = false
    var loadError: Error?
    /// Thrown from `phonemes(for:)`.
    var phonemesError: Error?
    private(set) var loadCalls = 0
    private(set) var downloadCalls = 0
    private(set) var phonemeTextCalls: [String] = []
    private(set) var synthesizeCalls: [(phonemes: String, voice: String, speed: Float)] = []

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func loadLocal() async throws -> any KokoroModelSession {
        loadCalls += 1
        if let loadError {
            throw loadError
        }
        return self
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession {
        downloadCalls += 1
        return self
    }

    func removeModels() async throws {}

    func phonemes(for text: String) async throws -> String {
        phonemeTextCalls.append(text)
        if let phonemesError {
            throw phonemesError
        }
        // Identity phonemization keeps the chunker deterministic: a short string yields one chunk.
        return text
    }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        synthesizeCalls.append((phonemes, voice, speed))
        return KokoroPCM(samples: [Float(phonemes.count)], sampleRate: 24_000)
    }
}
