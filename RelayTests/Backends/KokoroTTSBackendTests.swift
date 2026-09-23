import FluidAudio
import XCTest
@testable import Relay

@MainActor
final class KokoroTTSBackendTests: XCTestCase {
    func testIdentifiesAsKokoro() {
        let backend = KokoroTTSBackend(engine: FakeKokoroEngine())

        XCTAssertEqual(backend.id, "kokoro")
        XCTAssertEqual(backend.displayName, "Kokoro")
    }

    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = false
        let backend = KokoroTTSBackend(engine: engine)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        _ = await backend.availability()

        XCTAssertTrue(engine.loadCalls.isEmpty, "availability() must never load the engine")
    }

    func testMakeAudioSourceLazilyLoadsWithoutAllowingDownload() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(engine.loadCalls, [false])
    }

    func testMakeAudioSourcePhonemizesTheFullText() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(engine.phonemeTextCalls, ["hello"])
    }

    func testMakeAudioSourceUsesKokoroVoiceFromOptions() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let source = try await backend.makeAudioSource(text: "hello", options: .init(kokoroVoice: "am_adam"))
        try await drain(source)

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "am_adam")
    }

    func testMakeAudioSourceFallsBackToRecommendedVoiceWhenNoneConfigured() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let source = try await backend.makeAudioSource(text: "hello", options: .init(kokoroVoice: nil))
        try await drain(source)

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, TtsConstants.recommendedVoice)
    }

    func testMakeAudioSourceIgnoresAppleVoiceIdentifier() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let source = try await backend.makeAudioSource(
            text: "hello",
            options: .init(voiceIdentifier: "com.apple.voice.compact.en-US.Samantha", kokoroVoice: "af_bella")
        )
        try await drain(source)

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "af_bella")
    }

    func testMakeAudioSourceMapsSharedRateDefaultToNormalKokoroSpeed() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let source = try await backend.makeAudioSource(text: "hello", options: .init(rate: 0.5))
        try await drain(source)

        XCTAssertEqual(try XCTUnwrap(engine.synthesizeCalls.last?.speed), 1.0, accuracy: 0.0001)
    }

    func testMakeAudioSourceMapsSlowestAndFastestSharedRatesProportionally() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let slow = try await backend.makeAudioSource(text: "hello", options: .init(rate: 0.1))
        try await drain(slow)
        XCTAssertEqual(try XCTUnwrap(engine.synthesizeCalls.last?.speed), 0.2, accuracy: 0.0001)

        let fast = try await backend.makeAudioSource(text: "hello", options: .init(rate: 1.0))
        try await drain(fast)
        XCTAssertEqual(try XCTUnwrap(engine.synthesizeCalls.last?.speed), 2.0, accuracy: 0.0001)
    }

    func testMakeAudioSourceWithEmptyTextDoesNotCrash() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        let source = try await backend.makeAudioSource(text: "", options: .init())
        try await drain(source)

        XCTAssertEqual(engine.phonemeTextCalls.last, "")
    }

    func testMakeAudioSourceMapsModelNotDownloadedToFallbackWorthyError() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = false
        let backend = KokoroTTSBackend(engine: engine)

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
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.loadError = KokoroEngineError.loadFailed
        let backend = KokoroTTSBackend(engine: engine)

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
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.phonemesError = KokoroEngineError.synthesisFailed
        let backend = KokoroTTSBackend(engine: engine)

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
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.loadError = CancellationError()
        let backend = KokoroTTSBackend(engine: engine)

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
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.phonemesError = CancellationError()
        let backend = KokoroTTSBackend(engine: engine)

        do {
            _ = try await backend.makeAudioSource(text: "hello", options: .init())
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected - must not be remapped to SpeechBackendError
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testSecondMakeAudioSourceDoesNotTriggerASecondEngineLoad() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init())
        _ = try await backend.makeAudioSource(text: "world", options: .init())

        XCTAssertEqual(engine.loadCalls, [false], "A second makeAudioSource must not reload an already-loaded engine")
    }

    // MARK: Helpers

    /// Pulls a source to completion so its producer runs every `synthesize(phonemes:voice:speed:)`
    /// the backend wired up (voice/speed only reach the engine when the source is consumed).
    private func drain(_ source: any TTSAudioSource) async throws {
        while try await source.next() != nil {}
    }
}

@MainActor
private final class FakeKokoroEngine: KokoroEngine {
    var modelsPresent = false
    var loadError: Error?
    /// Thrown from `phonemes(for:)`.
    var phonemesError: Error?
    var progressToReport: [Double] = [0.5, 1.0]
    private(set) var loadCalls: [Bool] = []
    private(set) var phonemeTextCalls: [String] = []
    private(set) var synthesizeCalls: [(phonemes: String, voice: String, speed: Float)] = []
    private var isLoaded = false

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isLoaded else { return }
        loadCalls.append(allowDownload)
        if allowDownload {
            for fraction in progressToReport {
                progress(fraction)
            }
        }
        if let loadError {
            throw loadError
        }
        // Mirrors FluidAudioKokoroEngine's real contract: a local-only load refuses to proceed
        // when the model isn't present, exactly like the production presence gate.
        guard allowDownload || modelsPresent else {
            throw KokoroEngineError.modelsNotDownloaded
        }
        isLoaded = true
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
