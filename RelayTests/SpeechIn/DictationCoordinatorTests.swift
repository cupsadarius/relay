import XCTest
@testable import Relay

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    func testStartStopsSpeechBeforeStartingMicrophone() async {
        let events = EventLog()
        let microphone = FakeMicrophone(events: events)
        let coordinator = DictationCoordinator(
            microphone: microphone,
            sttRouter: router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events),
            stopSpeech: { events.append("speech.stop") },
            status: { _ in }
        )

        await coordinator.start()

        XCTAssertEqual(events.values, ["speech.stop", "microphone.start"])
    }

    func testFinishTranscribesProcessesAndInsertsText() async {
        let events = EventLog()
        let microphone = FakeMicrophone(events: events)
        let inserter = FakeTextInserter(events: events)
        let coordinator = DictationCoordinator(
            microphone: microphone,
            sttRouter: router(events: events, transcript: "  hello   relay  "),
            processor: RulesTranscriptProcessor(),
            textInserter: inserter,
            stopSpeech: { events.append("speech.stop") },
            status: { _ in }
        )
        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(inserter.inserted, ["hello relay"])
        XCTAssertEqual(events.values, ["speech.stop", "microphone.start", "microphone.stop", "stt.transcribe", "insert"])
    }

    func testTranscriptionFailureDoesNotInsertAndReportsActionableStatus() async {
        let events = EventLog()
        let microphone = FakeMicrophone(events: events)
        let inserter = FakeTextInserter(events: events)
        var statuses: [String] = []
        let coordinator = DictationCoordinator(
            microphone: microphone,
            sttRouter: router(events: events, error: .permissionDenied),
            processor: RulesTranscriptProcessor(),
            textInserter: inserter,
            stopSpeech: { events.append("speech.stop") },
            status: { statuses.append($0) }
        )
        await coordinator.start()
        await coordinator.finish()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(statuses.last, "Dictation failed: Allow Microphone permission in System Settings, then try again.")
    }

    func testDeniedInsertionPermissionDoesNotReportInsertedDictation() async {
        let events = EventLog()
        var statuses: [String] = []
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events), sttRouter: router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: ErrorTextInserter(error: TextInsertionError.accessibilityPermissionDenied),
            stopSpeech: {}, status: { statuses.append($0) }
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(statuses.last, "Dictation failed: Allow Accessibility permission in System Settings before inserting dictation.")
        XCTAssertFalse(statuses.contains("Inserted dictation"))
    }

    func testFailedStartClearsPendingFinishSoRetryRecords() async {
        let events = EventLog()
        let microphone = DelayedFailingMicrophone(events: events)
        let coordinator = DictationCoordinator(
            microphone: microphone, sttRouter: router(events: events), processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events), stopSpeech: {}, status: { _ in }
        )
        let firstStart = Task { await coordinator.start() }
        while !(await microphone.didStart()) { await Task.yield() }
        await coordinator.finish()
        await microphone.failStart()
        await firstStart.value

        await coordinator.start()

        XCTAssertEqual(events.values, ["microphone.start", "microphone.start"])
    }

    func testEveryKnownDictationErrorHasStableActionableStatus() async {
        let cases: [(Error, String)] = [
            (SpeechBackendError.unavailable("offline"), "Dictation failed: Speech recognition is unavailable. Try again after it is ready."),
            (SpeechBackendError.modelNotDownloaded, "Dictation failed: Download the Apple Speech assets, then try again."),
            (SpeechBackendError.initializationFailed("x"), "Dictation failed: Speech recognition could not start. Try again."),
            (SpeechBackendError.unsupportedOS, "Dictation failed: Apple Speech requires a newer version of macOS."),
            (SpeechBackendError.unsupportedHardware, "Dictation failed: Apple Speech is unavailable on this Mac."),
            (SpeechBackendError.inferenceFailed("x"), "Dictation failed: Speech recognition could not understand the audio. Try again."),
            (SpeechBackendError.resourceExhausted, "Dictation failed: Speech recognition is busy. Try again shortly."),
            (SpeechBackendError.permissionDenied, "Dictation failed: Allow Microphone permission in System Settings, then try again."),
            (SpeechBackendError.noUsableAudio, "Dictation failed: No usable audio was captured. Check your microphone and try again."),
            (SpeechBackendError.invalidInput, "Dictation failed: The recorded audio was invalid. Try again."),
            (TextInsertionError.clipboardWriteFailed, "Dictation failed: Relay could not insert text. Grant Accessibility permission and try again."),
            (TextInsertionError.accessibilityPermissionDenied, "Dictation failed: Allow Accessibility permission in System Settings before inserting dictation.")
        ]
        for (error, expected) in cases {
            let events = EventLog()
            var statuses: [String] = []
            let coordinator = DictationCoordinator(
                microphone: FakeMicrophone(events: events), sttRouter: router(events: events, error: error as? SpeechBackendError),
                processor: RulesTranscriptProcessor(), textInserter: ErrorTextInserter(error: error), stopSpeech: {}, status: { statuses.append($0) }
            )
            await coordinator.start()
            await coordinator.finish()
            XCTAssertEqual(statuses.last, expected)
        }
    }

    func testEveryMicrophoneErrorHasStableActionableStartStatus() async {
        let cases: [(MicrophoneCaptureError, String)] = [
            (.unavailable("x"), "Microphone is unavailable. Check its connection and permissions."),
            (.alreadyRecording, "Microphone recording is already in progress. Try again shortly."),
            (.notRecording, "Microphone recording was interrupted. Try again.")
        ]
        for (error, message) in cases {
            let events = EventLog()
            var statuses: [String] = []
            let coordinator = DictationCoordinator(
                microphone: ThrowingMicrophone(error: error), sttRouter: router(events: events),
                processor: RulesTranscriptProcessor(), textInserter: FakeTextInserter(events: events),
                stopSpeech: {}, status: { statuses.append($0) }
            )
            await coordinator.start()
            XCTAssertEqual(statuses.last, "Could not start dictation: \(message)")
        }
    }

    private func router(events: EventLog, transcript: String = "text", error: SpeechBackendError? = nil) -> STTRouter {
        let backend = FakeBackend(events: events, transcript: transcript, error: error)
        return STTRouter(backends: [backend.id: backend], backendOrder: { [backend] in [backend.id] })
    }
}

private actor DelayedFailingMicrophone: MicrophoneCapturing {
    let events: EventLog
    private var didInvokeStart = false
    private var attempts = 0
    private var started: CheckedContinuation<Void, Never>?
    init(events: EventLog) { self.events = events }
    func start() async throws {
        await events.append("microphone.start")
        attempts += 1
        didInvokeStart = true
        if attempts == 1 {
            await withCheckedContinuation { started = $0 }
            throw MicrophoneCaptureError.unavailable("x")
        }
    }
    func stop() async throws -> AudioInput { AudioInput(samples: [0.1], sampleRate: 16_000) }
    func didStart() -> Bool { didInvokeStart }
    func failStart() { started?.resume(); started = nil }
}

private struct ThrowingMicrophone: MicrophoneCapturing {
    let error: MicrophoneCaptureError
    func start() async throws { throw error }
    func stop() async throws -> AudioInput { throw error }
}

@MainActor
private final class ErrorTextInserter: TextInserting {
    let error: Error
    init(error: Error) { self.error = error }
    func insert(_ text: String) throws { throw error }
}

@MainActor
private final class EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor FakeMicrophone: MicrophoneCapturing {
    let events: EventLog
    init(events: EventLog) { self.events = events }
    func start() async throws { await events.append("microphone.start") }
    func stop() async throws -> AudioInput { await events.append("microphone.stop"); return AudioInput(samples: [0.1], sampleRate: 16_000) }
}

@MainActor
private final class FakeBackend: SpeechToTextBackend {
    let id = "fake"
    let displayName = "Fake"
    let capabilities = STTCapabilities([])
    let events: EventLog
    let transcript: String
    let error: SpeechBackendError?
    init(events: EventLog, transcript: String, error: SpeechBackendError?) { self.events = events; self.transcript = transcript; self.error = error }
    func availability() async -> BackendAvailability { .available }
    func prepare() async throws {}
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript { events.append("stt.transcribe"); if let error { throw error }; return Transcript(text: transcript, backendID: id) }
}

@MainActor
private final class FakeTextInserter: TextInserting {
    let events: EventLog
    private(set) var inserted: [String] = []
    init(events: EventLog) { self.events = events }
    func insert(_ text: String) throws { inserted.append(text); events.append("insert") }
}
