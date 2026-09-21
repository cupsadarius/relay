import AVFoundation
import FluidAudio
import XCTest
@testable import Relay

/// Cross-backend contract for `TextToSpeechBackend.speak(text:options:sessionID:)`: it validates
/// input, starts (or schedules) playback, and RETURNS as soon as playback has started - never
/// waiting for it to finish. Completion is reported later, asynchronously, through the installed
/// playback-event handler as exactly one terminal event (`finished`, `cancelled`, or `failed`).
/// Every backend (Apple, Kokoro, PocketTTS) must honor this same return-point contract, even
/// though only Apple's `AVSpeechSynthesizer` shape made it obviously true before this test existed
/// - Kokoro and PocketTTS used to block `speak()` until their player reached a terminal state.
@MainActor
final class TTSBackendContractTests: XCTestCase {
    // MARK: - Apple

    func testAppleSpeakReturnsBeforeTerminalEventThenHandlerObservesTerminalLater() async throws {
        let synthesizer = FakeContractAppleSynthesizer()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()

        try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)

        // speak() has already returned here. Apple's terminal event only ever arrives later via
        // the AVSpeechSynthesizerDelegate callback, so nothing terminal can have fired yet.
        XCTAssertEqual(events, [.scheduled(sessionID: sessionID)])
        XCTAssertFalse(events.contains(where: \.isTerminal))

        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)
        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: utterance)
        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)

        XCTAssertEqual(events, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
    }

    // MARK: - Kokoro

    func testKokoroSpeakReturnsBeforeTerminalEventThenHandlerObservesTerminalLater() async throws {
        let engine = FakeContractKokoroEngine()
        engine.modelsPresent = true
        let player = FakeContractSynthesizedPlayer()
        let backend = KokoroTTSBackend(engine: engine, player: player)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()

        try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)

        // speak() has already returned here. The fake player never emits a terminal event on its
        // own - only `.scheduled`/`.started` synchronously inside `startPlayback`, matching the
        // non-blocking start API this task adds. If `speak()` were still (incorrectly) awaiting
        // the player all the way to a terminal state, this call would never have returned.
        XCTAssertEqual(events, [.scheduled(sessionID: sessionID), .started(sessionID: sessionID)])
        XCTAssertFalse(events.contains(where: \.isTerminal))

        player.emitFinished(sessionID: sessionID)

        XCTAssertEqual(events, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
    }

    // MARK: - PocketTTS

    func testPocketTTSSpeakReturnsBeforeTerminalEventThenHandlerObservesTerminalLater() async throws {
        let engine = FakeContractPocketTTSEngine()
        engine.modelsPresent = true
        engine.synthesizeStreamFrames = [[0.1, 0.2, 0.3]]
        let player = FakeContractStreamingPlayer()
        let backend = PocketTTSBackend(engine: engine, player: player)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()

        try await backend.speak(text: "hello", options: .init(), sessionID: sessionID)

        XCTAssertEqual(events, [.scheduled(sessionID: sessionID), .started(sessionID: sessionID)])
        XCTAssertFalse(events.contains(where: \.isTerminal))

        player.emitFinished(sessionID: sessionID)

        XCTAssertEqual(events, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
    }
}

private extension TTSPlaybackEvent {
    var isTerminal: Bool {
        switch self {
        case .finished, .cancelled, .failed: true
        case .scheduled, .started, .level: false
        }
    }
}

// MARK: - Apple fake

@MainActor
private final class FakeContractAppleSynthesizer: AppleSpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?
    private(set) var spokenUtterances: [AVSpeechUtterance] = []

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func continueSpeaking() -> Bool { true }
}

// MARK: - Kokoro fakes

@MainActor
private final class FakeContractKokoroEngine: KokoroEngine {
    var modelsPresent = false
    private var isLoaded = false

    func modelsArePresent() async -> Bool { modelsPresent }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isLoaded else { return }
        guard allowDownload || modelsPresent else {
            throw KokoroEngineError.modelsNotDownloaded
        }
        isLoaded = true
    }

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        Data([1, 2, 3])
    }
}

@MainActor
private final class FakeContractSynthesizedPlayer: SynthesizedAudioPlaying {
    var onEvent: (@MainActor @Sendable (TTSPlaybackEvent) -> Void)?

    /// Starts playback and returns immediately, exactly like the real `SynthesizedAudioPlayer`:
    /// `.scheduled` then `.started` fire synchronously here, and no terminal event is ever
    /// emitted from inside this call - only `emitFinished(sessionID:)`, called separately by the
    /// test after `speak()` has already returned, produces one.
    func startPlayback(_ wav: Data, sessionID: UUID) async throws {
        onEvent?(.scheduled(sessionID: sessionID))
        onEvent?(.started(sessionID: sessionID))
    }

    func emitFinished(sessionID: UUID) {
        onEvent?(.finished(sessionID: sessionID))
    }

    func stop() {}
    func pause() {}
    func resume() {}
}

// MARK: - PocketTTS fakes

@MainActor
private final class FakeContractPocketTTSEngine: PocketTTSEngine {
    var modelsPresent = false
    var synthesizeStreamFrames: [[Float]] = []
    private var isLoaded = false

    func modelsArePresent() async -> Bool { modelsPresent }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isLoaded else { return }
        guard allowDownload || modelsPresent else {
            throw PocketTTSEngineError.modelsNotDownloaded
        }
        isLoaded = true
    }

    func synthesize(text: String, voice: String) async throws -> Data { Data() }

    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let frames = synthesizeStreamFrames
        return AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

@MainActor
private final class FakeContractStreamingPlayer: StreamingAudioPlaying {
    var onEvent: (@MainActor @Sendable (TTSPlaybackEvent) -> Void)?

    /// Drains the frame stream (mirroring how the real `StreamingAudioPlayer` consumes it while
    /// prebuffering), then starts playback and returns immediately: `.scheduled` then `.started`
    /// fire synchronously here, and no terminal event is ever emitted from inside this call - only
    /// `emitFinished(sessionID:)`, called separately by the test after `speak()` has already
    /// returned, produces one.
    func startPlayback(_ frames: AsyncThrowingStream<[Float], Error>, sampleRate: Double, sessionID: UUID) async throws {
        for try await _ in frames {}
        onEvent?(.scheduled(sessionID: sessionID))
        onEvent?(.started(sessionID: sessionID))
    }

    func startPlayback(_ source: any TTSAudioSource, sessionID: UUID) async throws {
        while try await source.next() != nil {}
        onEvent?(.scheduled(sessionID: sessionID))
        onEvent?(.started(sessionID: sessionID))
    }

    func emitFinished(sessionID: UUID) {
        onEvent?(.finished(sessionID: sessionID))
    }

    func stop() {}
    func pause() {}
    func resume() {}
}
