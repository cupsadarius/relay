import FluidAudio
import XCTest
@testable import Relay

@MainActor
final class KokoroTTSBackendTests: XCTestCase {
    func testIdentifiesAsKokoro() {
        let backend = KokoroTTSBackend(engine: FakeKokoroEngine(), player: FakePlayer())

        XCTAssertEqual(backend.id, "kokoro")
        XCTAssertEqual(backend.displayName, "Kokoro")
    }

    func testCapabilities() {
        let backend = KokoroTTSBackend(engine: FakeKokoroEngine(), player: FakePlayer())

        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
        XCTAssertTrue(backend.capabilities.contains(.voiceSelection))
        XCTAssertTrue(backend.capabilities.contains(.pauseResume))
        XCTAssertTrue(backend.capabilities.contains(.outputLevel))
        XCTAssertFalse(backend.capabilities.contains(.streaming))
    }

    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = false
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        _ = await backend.availability()

        XCTAssertTrue(engine.loadCalls.isEmpty, "availability() must never load the engine")
    }

    func testSpeakLazilyLoadsWithoutAllowingDownload() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertEqual(engine.loadCalls, [false])
    }

    func testSpeakUsesKokoroVoiceFromOptions() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(kokoroVoice: "am_adam"), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "am_adam")
    }

    func testSpeakFallsBackToRecommendedVoiceWhenNoneConfigured() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(kokoroVoice: nil), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, TtsConstants.recommendedVoice)
    }

    func testSpeakIgnoresAppleVoiceIdentifier() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(
            text: "hello",
            options: .init(voiceIdentifier: "com.apple.voice.compact.en-US.Samantha", kokoroVoice: "af_bella"),
            sessionID: UUID()
        )

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "af_bella")
    }

    func testSpeakMapsSharedRateDefaultToNormalKokoroSpeed() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(rate: 0.5), sessionID: UUID())

        XCTAssertEqual(try XCTUnwrap(engine.synthesizeCalls.last?.speed), 1.0, accuracy: 0.0001)
    }

    func testSpeakMapsSlowestAndFastestSharedRatesProportionally() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(rate: 0.1), sessionID: UUID())
        XCTAssertEqual(try XCTUnwrap(engine.synthesizeCalls.last?.speed), 0.2, accuracy: 0.0001)

        try await backend.speak(text: "hello", options: .init(rate: 1.0), sessionID: UUID())
        XCTAssertEqual(try XCTUnwrap(engine.synthesizeCalls.last?.speed), 2.0, accuracy: 0.0001)
    }

    func testSpeakHandsSynthesizedWavToThePlayerWithTheSameSessionID() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.synthesizeResult = Data([1, 2, 3])
        let player = FakePlayer()
        let backend = KokoroTTSBackend(engine: engine, player: player)
        let sessionID = UUID()

        try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(player.playCalls.count, 1)
        XCTAssertEqual(player.playCalls.first?.wav, Data([1, 2, 3]))
        XCTAssertEqual(player.playCalls.first?.sessionID, sessionID)
    }

    func testSpeakForwardsPlayerEventsToTheInstalledHandler() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let player = FakePlayer()
        let backend = KokoroTTSBackend(engine: engine, player: player)
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()
        player.emitOnPlay = [.scheduled(sessionID: sessionID), .started(sessionID: sessionID), .finished(sessionID: sessionID)]

        try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(received, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
    }

    func testSpeakWithEmptyTextDoesNotCrash() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "", options: .init(), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.last?.text, "")
    }

    func testSpeakMapsModelNotDownloadedToFallbackWorthyError() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = false
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: UUID())
            XCTFail("Expected modelNotDownloaded")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .modelNotDownloaded)
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testSpeakMapsLoadFailureToFallbackWorthyErrorWithoutEmittingFailed() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.loadError = KokoroEngineError.loadFailed
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected initializationFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .initializationFailed("Kokoro model load failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
        // TTSRouter centralizes `.failed`, emitting it only once all backends are exhausted -
        // the backend itself must never emit it, or a successful Apple fallback would still
        // show a stale failure in the UI.
        XCTAssertFalse(received.contains(.failed(sessionID: sessionID)), "Backend must not emit .failed - TTSRouter owns that")
    }

    func testSpeakMapsSynthesisFailureToFallbackWorthyErrorWithoutEmittingFailed() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        engine.synthesizeError = KokoroEngineError.synthesisFailed
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected inferenceFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .inferenceFailed("Kokoro synthesis failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
        XCTAssertFalse(received.contains(.failed(sessionID: sessionID)), "Backend must not emit .failed - TTSRouter owns that")
    }

    func testSpeakMapsPlaybackFailureToFallbackWorthyErrorWithoutEmittingFailed() async {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let player = FakePlayer()
        player.playError = SynthesizedAudioPlayerError.bufferAllocationFailed
        let backend = KokoroTTSBackend(engine: engine, player: player)
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected inferenceFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .inferenceFailed("Kokoro playback failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
        // Uniform terminal-event contract: even when `.started` already fired before playback
        // failed, the backend still must not emit `.failed` itself.
        XCTAssertFalse(received.contains(.failed(sessionID: sessionID)), "Backend must not emit .failed - TTSRouter owns that")
    }

    func testStopPauseResumeDelegateToThePlayer() {
        let player = FakePlayer()
        let backend = KokoroTTSBackend(engine: FakeKokoroEngine(), player: player)

        backend.stop()
        backend.pause()
        backend.resume()

        XCTAssertEqual(player.stopCallCount, 1)
        XCTAssertEqual(player.pauseCallCount, 1)
        XCTAssertEqual(player.resumeCallCount, 1)
    }

    func testSecondSpeakDoesNotTriggerASecondEngineLoad() async throws {
        let engine = FakeKokoroEngine()
        engine.modelsPresent = true
        let backend = KokoroTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(), sessionID: UUID())
        try await backend.speak(text: "world", options: .init(), sessionID: UUID())

        XCTAssertEqual(engine.loadCalls, [false], "A second speak must not reload an already-loaded engine")
    }
}

@MainActor
private final class FakeKokoroEngine: KokoroEngine {
    var modelsPresent = false
    var loadError: Error?
    var synthesizeError: Error?
    var synthesizeResult = Data()
    var progressToReport: [Double] = [0.5, 1.0]
    private(set) var loadCalls: [Bool] = []
    private(set) var synthesizeCalls: [(text: String, voice: String, speed: Float)] = []
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

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        synthesizeCalls.append((text, voice, speed))
        if let synthesizeError {
            throw synthesizeError
        }
        return synthesizeResult
    }
}

@MainActor
private final class FakePlayer: SynthesizedAudioPlaying {
    var onEvent: (@MainActor @Sendable (TTSPlaybackEvent) -> Void)?
    var playError: Error?
    /// Events this fake emits (via `onEvent`) from inside a successful `play(_:sessionID:)` call,
    /// simulating the real player's lifecycle.
    var emitOnPlay: [TTSPlaybackEvent] = []
    private(set) var playCalls: [(wav: Data, sessionID: UUID)] = []
    private(set) var stopCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0

    func startPlayback(_ wav: Data, sessionID: UUID) async throws {
        playCalls.append((wav, sessionID))
        if let playError {
            throw playError
        }
        for event in emitOnPlay {
            onEvent?(event)
        }
    }

    func stop() { stopCallCount += 1 }
    func pause() { pauseCallCount += 1 }
    func resume() { resumeCallCount += 1 }
}

/// Sendable accumulator for progress callbacks. `@escaping @Sendable` closures can't safely
/// capture a mutable local `var`, so tests that record progress ticks use this instead.
private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}
