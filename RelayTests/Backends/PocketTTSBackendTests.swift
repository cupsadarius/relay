import FluidAudio
import XCTest
@testable import Relay

@MainActor
final class PocketTTSBackendTests: XCTestCase {
    func testIdentifiesAsPocketTTS() {
        let backend = PocketTTSBackend(engine: FakePocketTTSEngine())

        XCTAssertEqual(backend.id, "pocket-tts")
        XCTAssertEqual(backend.displayName, "PocketTTS")
    }

    func testCapabilities() {
        let backend = PocketTTSBackend(engine: FakePocketTTSEngine())

        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
        XCTAssertTrue(backend.capabilities.contains(.voiceSelection))
        XCTAssertTrue(backend.capabilities.contains(.pauseResume))
        XCTAssertTrue(backend.capabilities.contains(.outputLevel))
        XCTAssertTrue(backend.capabilities.contains(.streaming))
    }

    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = false
        let backend = PocketTTSBackend(engine: engine)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = await backend.availability()

        XCTAssertTrue(engine.loadCalls.isEmpty, "availability() must never load the engine")
    }

    func testMakeAudioSourceLazilyLoadsWithoutAllowingDownload() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init())

        XCTAssertEqual(engine.loadCalls, [false])
    }

    func testMakeAudioSourceUsesPocketVoiceFromOptions() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init(pocketVoice: "alba"))

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "alba")
    }

    func testMakeAudioSourceFallsBackToDefaultVoiceWhenNoneConfigured() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init(pocketVoice: nil))

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, PocketTtsConstants.defaultVoice)
    }

    func testMakeAudioSourceIgnoresAppleAndKokoroVoiceIdentifiers() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(
            text: "hello",
            options: .init(
                voiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
                kokoroVoice: "af_bella",
                pocketVoice: "alba"
            )
        )

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "alba")
    }

    func testMakeAudioSourceIgnoresTheSharedRateSlider() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init(rate: 0.1))
        _ = try await backend.makeAudioSource(text: "hello", options: .init(rate: 1.0))

        XCTAssertEqual(engine.synthesizeCalls.map(\.text), ["hello", "hello"])
    }

    func testMakeAudioSourceProducesTheEngineStreamFramesAtThePocketSampleRate() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.synthesizeStreamFrames = [[1, 2, 3], [4, 5, 6]]
        let backend = PocketTTSBackend(engine: engine)

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "", options: .init())

        XCTAssertEqual(engine.synthesizeCalls.last?.text, "")
    }

    func testMakeAudioSourceMapsModelNotDownloadedToFallbackWorthyError() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = false
        let backend = PocketTTSBackend(engine: engine)

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.loadError = PocketTTSEngineError.loadFailed
        let backend = PocketTTSBackend(engine: engine)

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.synthesizeError = PocketTTSEngineError.synthesisFailed
        let backend = PocketTTSBackend(engine: engine)

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.loadError = CancellationError()
        let backend = PocketTTSBackend(engine: engine)

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.synthesizeError = CancellationError()
        let backend = PocketTTSBackend(engine: engine)

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine)

        _ = try await backend.makeAudioSource(text: "hello", options: .init())
        _ = try await backend.makeAudioSource(text: "world", options: .init())

        XCTAssertEqual(engine.loadCalls, [false], "A second makeAudioSource must not reload an already-loaded engine")
    }
}

@MainActor
private final class FakePocketTTSEngine: PocketTTSEngine {
    var modelsPresent = false
    var loadError: Error?
    /// Thrown synchronously from `synthesizeStream` itself (mirroring the real engine's "not
    /// loaded" guard, or a mapped session failure) - never from inside the returned stream.
    var synthesizeError: Error?
    /// Canned frames the returned stream yields, in order, before finishing.
    var synthesizeStreamFrames: [[Float]] = []
    var progressToReport: [Double] = [0.5, 1.0]
    private(set) var loadCalls: [Bool] = []
    private(set) var synthesizeCalls: [(text: String, voice: String)] = []
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
        // Mirrors FluidAudioPocketTTSEngine's real contract: a local-only load refuses to
        // proceed when the model isn't present, exactly like the production presence gate.
        guard allowDownload || modelsPresent else {
            throw PocketTTSEngineError.modelsNotDownloaded
        }
        isLoaded = true
    }

    /// Unused by `PocketTTSBackend` since it moved to the streaming path, but still part of the
    /// `PocketTTSEngine` protocol.
    func synthesize(text: String, voice: String) async throws -> Data {
        synthesizeCalls.append((text, voice))
        if let synthesizeError {
            throw synthesizeError
        }
        return Data()
    }

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
