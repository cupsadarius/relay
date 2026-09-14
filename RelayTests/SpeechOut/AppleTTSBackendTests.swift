import AVFoundation
import XCTest
@testable import Relay

@MainActor
final class AppleTTSBackendTests: XCTestCase {
    func testAppleBackendReportsSupportedCapabilities() {
        let backend = AppleTTSBackend(synthesizer: FakeAppleSpeechSynthesizing())

        XCTAssertTrue(backend.capabilities.contains(.voiceSelection))
        XCTAssertTrue(backend.capabilities.contains(.pauseResume))
        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
    }

    func testScheduledEventEmittedBeforeCallingSynthesizerSpeak() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var order: [String] = []
        synthesizer.onSpeak = { order.append("synthesizer.speak") }
        backend.setPlaybackEventHandler { event in
            if case .scheduled = event { order.append("scheduled") }
        }

        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: UUID())

        XCTAssertEqual(order, ["scheduled", "synthesizer.speak"])
    }

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

    func testStopClearsTrackedUtterancesBeforeStoppingSoLateCancelEmitsNothing() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: UUID())
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)
        events.removeAll()

        backend.stop()
        synthesizer.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)

        XCTAssertTrue(events.isEmpty, "A late didCancel for an utterance stop() already dropped must not emit")
    }

    func testDelegateCallbackFromBackgroundThreadStillDeliversEvent() async throws {
        let synthesizer = FakeAppleSpeechSynthesizing()
        let backend = AppleTTSBackend(synthesizer: synthesizer)
        let sessionID = UUID()
        try await backend.speak(text: "hello", options: TTSOptions(), sessionID: sessionID)
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)
        let realSynthesizer = AVSpeechSynthesizer()

        let delivered = expectation(description: "started event delivered")
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { event in
            events.append(event)
            delivered.fulfill()
        }

        // Boxed for identity only: the background thread only forwards these references
        // into a delegate callback, never mutates them, so the lack of `Sendable` conformance
        // on `AVSpeechSynthesizer`/`AVSpeechUtterance` doesn't matter here.
        let synthesizerBox = UncheckedSendableBox(value: realSynthesizer)
        let utteranceBox = UncheckedSendableBox(value: utterance)
        Thread.detachNewThread {
            backend.speechSynthesizer(synthesizerBox.value, didStart: utteranceBox.value)
        }

        await fulfillment(of: [delivered], timeout: 2.0)
        XCTAssertEqual(events, [.started(sessionID: sessionID)])
    }
}

@MainActor
private final class FakeAppleSpeechSynthesizing: AppleSpeechSynthesizing {
    // Held weakly, matching the real AVSpeechSynthesizer and the protocol's
    // documented contract, since AppleTTSBackend owns both its synthesizer
    // and (as the delegate) itself.
    weak var delegate: AVSpeechSynthesizerDelegate?
    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var continueCount = 0
    var onSpeak: (() -> Void)?

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
        onSpeak?()
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

/// Boxes a non-`Sendable` value for identity-only handoff across a thread boundary in tests.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(value: T) { self.value = value }
}
