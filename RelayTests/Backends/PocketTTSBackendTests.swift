import FluidAudio
import XCTest
@testable import Relay

@MainActor
final class PocketTTSBackendTests: XCTestCase {
    func testIdentifiesAsPocketTTS() {
        let backend = PocketTTSBackend(engine: FakePocketTTSEngine(), player: FakePlayer())

        XCTAssertEqual(backend.id, "pocket-tts")
        XCTAssertEqual(backend.displayName, "PocketTTS")
    }

    func testCapabilities() {
        let backend = PocketTTSBackend(engine: FakePocketTTSEngine(), player: FakePlayer())

        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
        XCTAssertTrue(backend.capabilities.contains(.voiceSelection))
        XCTAssertTrue(backend.capabilities.contains(.pauseResume))
        XCTAssertTrue(backend.capabilities.contains(.outputLevel))
        XCTAssertTrue(backend.capabilities.contains(.streaming))
    }

    func testAvailabilityIsAvailableWhenModelsArePresent() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityIsModelNotDownloadedWhenModelsAreAbsent() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = false
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityNeverTriggersLoad() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        _ = await backend.availability()

        XCTAssertTrue(engine.loadCalls.isEmpty, "availability() must never load the engine")
    }

    func testSpeakLazilyLoadsWithoutAllowingDownload() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(), sessionID: UUID())

        XCTAssertEqual(engine.loadCalls, [false])
    }

    func testSpeakUsesPocketVoiceFromOptions() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(pocketVoice: "alba"), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "alba")
    }

    func testSpeakFallsBackToDefaultVoiceWhenNoneConfigured() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(pocketVoice: nil), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, PocketTtsConstants.defaultVoice)
    }

    func testSpeakIgnoresAppleAndKokoroVoiceIdentifiers() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(
            text: "hello",
            options: .init(
                voiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
                kokoroVoice: "af_bella",
                pocketVoice: "alba"
            ),
            sessionID: UUID()
        )

        XCTAssertEqual(engine.synthesizeCalls.last?.voice, "alba")
    }

    func testSpeakIgnoresTheSharedRateSlider() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(rate: 0.1), sessionID: UUID())
        try await backend.speak(text: "hello", options: .init(rate: 1.0), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.map(\.text), ["hello", "hello"])
    }

    func testSpeakHandsSynthesizedWavToThePlayerWithTheSameSessionID() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.synthesizeResult = Data([1, 2, 3])
        let player = FakePlayer()
        let backend = PocketTTSBackend(engine: engine, player: player)
        let sessionID = UUID()

        try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(player.playCalls.count, 1)
        XCTAssertEqual(player.playCalls.first?.wav, Data([1, 2, 3]))
        XCTAssertEqual(player.playCalls.first?.sessionID, sessionID)
    }

    func testSpeakForwardsPlayerEventsToTheInstalledHandler() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let player = FakePlayer()
        let backend = PocketTTSBackend(engine: engine, player: player)
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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "", options: .init(), sessionID: UUID())

        XCTAssertEqual(engine.synthesizeCalls.last?.text, "")
    }

    func testSpeakMapsModelNotDownloadedToFallbackWorthyError() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = false
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

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
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.loadError = PocketTTSEngineError.loadFailed
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected initializationFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .initializationFailed("PocketTTS model load failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
        // TTSRouter centralizes `.failed`, emitting it only once all backends are exhausted -
        // the backend itself must never emit it, or a successful Apple fallback would still
        // show a stale failure in the UI.
        XCTAssertFalse(received.contains(.failed(sessionID: sessionID)), "Backend must not emit .failed - TTSRouter owns that")
    }

    func testSpeakMapsSynthesisFailureToFallbackWorthyErrorWithoutEmittingFailed() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        engine.synthesizeError = PocketTTSEngineError.synthesisFailed
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected inferenceFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .inferenceFailed("PocketTTS synthesis failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
        XCTAssertFalse(received.contains(.failed(sessionID: sessionID)), "Backend must not emit .failed - TTSRouter owns that")
    }

    func testSpeakMapsPlaybackFailureToFallbackWorthyErrorWithoutEmittingFailed() async {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let player = FakePlayer()
        player.playError = SynthesizedAudioPlayerError.bufferAllocationFailed
        let backend = PocketTTSBackend(engine: engine, player: player)
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }
        let sessionID = UUID()

        do {
            try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected inferenceFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .inferenceFailed("PocketTTS playback failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
        // Uniform terminal-event contract: even when `.started` already fired before playback
        // failed, the backend still must not emit `.failed` itself.
        XCTAssertFalse(received.contains(.failed(sessionID: sessionID)), "Backend must not emit .failed - TTSRouter owns that")
    }

    func testDownloadModelsCallsEngineWithDownloadAllowedAndForwardsProgress() async throws {
        let engine = FakePocketTTSEngine()
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())
        let reported = ProgressBox()

        try await backend.downloadModels(progress: { reported.values.append($0) })

        XCTAssertEqual(engine.loadCalls, [true])
        XCTAssertEqual(reported.values, [0.5, 1.0])
    }

    func testDownloadModelsMapsEngineFailureToFallbackWorthyError() async {
        let engine = FakePocketTTSEngine()
        engine.loadError = PocketTTSEngineError.loadFailed
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        do {
            try await backend.downloadModels(progress: { _ in })
            XCTFail("Expected initializationFailed")
        } catch {
            let mapped = error as? SpeechBackendError
            XCTAssertEqual(mapped, .initializationFailed("PocketTTS model load failed"))
            XCTAssertEqual(mapped?.isFallbackWorthy, true)
        }
    }

    func testDownloadModelsDoesNotEmitAnyPlaybackEvent() async throws {
        let engine = FakePocketTTSEngine()
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())
        var received: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { received.append($0) }

        try await backend.downloadModels(progress: { _ in })

        XCTAssertTrue(received.isEmpty, "A model download is not a playback session and must not emit playback events")
    }

    func testStopPauseResumeDelegateToThePlayer() {
        let player = FakePlayer()
        let backend = PocketTTSBackend(engine: FakePocketTTSEngine(), player: player)

        backend.stop()
        backend.pause()
        backend.resume()

        XCTAssertEqual(player.stopCallCount, 1)
        XCTAssertEqual(player.pauseCallCount, 1)
        XCTAssertEqual(player.resumeCallCount, 1)
    }

    func testSecondSpeakDoesNotTriggerASecondEngineLoad() async throws {
        let engine = FakePocketTTSEngine()
        engine.modelsPresent = true
        let backend = PocketTTSBackend(engine: engine, player: FakePlayer())

        try await backend.speak(text: "hello", options: .init(), sessionID: UUID())
        try await backend.speak(text: "world", options: .init(), sessionID: UUID())

        XCTAssertEqual(engine.loadCalls, [false], "A second speak must not reload an already-loaded engine")
    }
}

/// Sendable accumulator for progress callbacks. `@escaping @Sendable` closures can't safely
/// capture a mutable local `var`, so tests that record progress ticks use this instead.
private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

@MainActor
private final class FakePocketTTSEngine: PocketTTSEngine {
    var modelsPresent = false
    var loadError: Error?
    var synthesizeError: Error?
    var synthesizeResult = Data()
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

    func synthesize(text: String, voice: String) async throws -> Data {
        synthesizeCalls.append((text, voice))
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

    func play(_ wav: Data, sessionID: UUID) async throws {
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
