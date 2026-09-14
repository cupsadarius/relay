import AVFoundation
import XCTest
@testable import Relay

@MainActor
final class AppleTTSBackendTests: XCTestCase {
    func testSpeakSchedulesUtteranceAndEmitsScheduledEvent() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()

        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: sessionID)

        XCTAssertEqual(synthesizer.spokenUtterances.count, 1)
        XCTAssertEqual(events, [.scheduled(sessionID: sessionID)])
    }

    func testInvalidVoiceIdentifierThrowsWithoutSpeakingOrEmitting() async {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }

        do {
            try await backend.speak(
                text: "hello",
                options: TTSOptions(voiceIdentifier: "not-a-real-voice"),
                sessionID: UUID()
            )
            XCTFail("Expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
        XCTAssertTrue(synthesizer.spokenUtterances.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testDelegateDidStartMapsToStartedEventForMatchingUtterance() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: sessionID)
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)

        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: utterance)

        XCTAssertEqual(events.last, .started(sessionID: sessionID))
    }

    func testDelegateDidFinishMapsToFinishedEventAndClearsTrackedSession() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: sessionID)
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)

        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
        events.removeAll()
        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)

        XCTAssertTrue(events.isEmpty, "A repeated terminal callback for the same utterance must not re-emit")
    }

    func testDelegateDidFinishEmitsFinishedEvent() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: sessionID)
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)

        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)

        XCTAssertEqual(events.last, .finished(sessionID: sessionID))
    }

    func testDelegateDidCancelMapsToCancelledEvent() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sessionID = UUID()
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: sessionID)
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)

        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)

        XCTAssertEqual(events.last, .cancelled(sessionID: sessionID))
    }

    func testUnknownUtteranceCallbackIsIgnored() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: UUID())
        events.removeAll()

        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: AVSpeechUtterance(string: "other"))

        XCTAssertTrue(events.isEmpty)
    }

    func testStopPauseResumeForwardToSynthesizer() {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)

        backend.stop()
        backend.pause()
        backend.resume()

        XCTAssertEqual(synthesizer.stopCount, 1)
        XCTAssertEqual(synthesizer.pauseCount, 1)
        XCTAssertEqual(synthesizer.continueCount, 1)
    }
}

@MainActor
private final class FakeAppleSpeechSynthesizing: AppleSpeechSynthesizing {
    var delegate: AVSpeechSynthesizerDelegate?
    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var continueCount = 0

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        return true
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauseCount += 1
        return true
    }

    func continueSpeaking() -> Bool {
        continueCount += 1
        return true
    }
}
