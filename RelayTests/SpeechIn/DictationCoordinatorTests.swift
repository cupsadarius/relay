import XCTest
@testable import Relay

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    func testStartStopsSpeechBeforeMicrophoneStartsAndBeforeListenAppears() async {
        let events = EventLog()
        let microphone = FakeMicrophone(events: events)
        let overlay = RecordingActivityOverlay(trace: events)
        let coordinator = makeCoordinator(microphone: microphone, stopSpeech: { events.append("speech.stop") }, overlay: overlay)

        await coordinator.start()

        XCTAssertEqual(events.values, ["speech.stop", "microphone.start", "overlay.listen"])
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
            status: { _ in },
            activity: RecordingActivityOverlay()
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
            status: { statuses.append($0) },
            activity: RecordingActivityOverlay()
        )
        await coordinator.start()
        await coordinator.finish()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(statuses.last, "Dictation failed: Allow Microphone permission in System Settings, then try again.")
    }

    func testRecordsFailureAtTranscriptionStage() async {
        let events = EventLog()
        let diagnostics = DiagnosticsRecorder()
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events),
            sttRouter: router(events: events, error: .permissionDenied),
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events),
            stopSpeech: {},
            status: { _ in },
            activity: RecordingActivityOverlay(),
            diagnostics: diagnostics
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(diagnostics.entries.map(\.event), [.dictation(.listening), .dictation(.processing), .dictation(.failed(.transcription))])
    }

    func testRecordsMicrophoneCaptureFailureAtStart() async {
        let events = EventLog()
        let diagnostics = DiagnosticsRecorder()
        let coordinator = DictationCoordinator(
            microphone: ThrowingMicrophone(error: .unavailable("capture unavailable")),
            sttRouter: router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events),
            stopSpeech: {},
            status: { _ in },
            activity: RecordingActivityOverlay(),
            diagnostics: diagnostics
        )

        await coordinator.start()

        XCTAssertEqual(diagnostics.entries.map(\.event), [.dictation(.failed(.microphoneCapture))])
    }

    func testRecordsInsertionMechanismReportedByInserterOnSuccess() async {
        let events = EventLog()
        let diagnostics = DiagnosticsRecorder()
        let inserter = FakeTextInserter(events: events, mechanism: .paste)
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events),
            sttRouter: router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: inserter,
            stopSpeech: {},
            status: { _ in },
            activity: RecordingActivityOverlay(),
            diagnostics: diagnostics
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(diagnostics.entries.last?.event, .dictation(.inserted(.paste)))
    }

    func testDiagnosticsNeverIncludeDictatedTextContent() async {
        let events = EventLog()
        let diagnostics = DiagnosticsRecorder()
        let sentinel = "SECRET-PHRASE-42"
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events),
            sttRouter: router(events: events, transcript: sentinel),
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events),
            stopSpeech: {},
            status: { _ in },
            activity: RecordingActivityOverlay(),
            diagnostics: diagnostics
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertFalse(diagnostics.copyText.contains(sentinel))
    }

    func testRecordsFailureAtInsertionStage() async {
        let events = EventLog()
        let diagnostics = DiagnosticsRecorder()
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events),
            sttRouter: router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: ErrorTextInserter(error: TextInsertionError.clipboardWriteFailed),
            stopSpeech: {},
            status: { _ in },
            activity: RecordingActivityOverlay(),
            diagnostics: diagnostics
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(diagnostics.entries.last?.event, .dictation(.failed(.insertion)))
    }

    func testDeniedInsertionPermissionDoesNotReportInsertedDictation() async {
        let events = EventLog()
        var statuses: [String] = []
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events), sttRouter: router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: ErrorTextInserter(error: TextInsertionError.accessibilityPermissionDenied),
            stopSpeech: {}, status: { statuses.append($0) },
            activity: RecordingActivityOverlay()
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(statuses.last, "Dictation failed: Allow Accessibility permission in System Settings before inserting dictation.")
        XCTAssertFalse(statuses.contains("Inserted dictation"))
    }

    /// Regression test: the backend-name lookup in `start()` suspends on an `await`. If a
    /// concurrent `finish()` is admitted during that suspension and runs the entire processing
    /// pipeline to completion before `start()` resumes, the "Listening…" status and `.listening`
    /// diagnostic must already have been recorded — not appended late, after "Inserted dictation".
    func testStaleListeningStatusAndDiagnosticCannotLandAfterConcurrentFinishCompletes() async {
        let probe = BlockingAvailabilityBackend()
        let sttRouter = STTRouter(backends: [probe.id: probe], backendOrder: { [probe.id] })
        let events = EventLog()
        let diagnostics = DiagnosticsRecorder()
        var statuses: [String] = []
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events),
            sttRouter: sttRouter,
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events),
            stopSpeech: {},
            status: { statuses.append($0) },
            activity: RecordingActivityOverlay(),
            diagnostics: diagnostics
        )

        let startTask = Task { await coordinator.start() }
        // `start()` records "Listening…" synchronously, then suspends on the blocked backend-name
        // lookup below - waiting for that status confirms it's now parked there.
        await waitUntil { statuses.last == "Listening…" }

        await coordinator.finish()

        XCTAssertEqual(statuses.last, "Inserted dictation")
        let diagnosticsAfterFinish = diagnostics.entries.map(\.event)

        probe.release()
        await startTask.value

        XCTAssertEqual(statuses.last, "Inserted dictation")
        XCTAssertEqual(diagnostics.entries.map(\.event), diagnosticsAfterFinish)
    }

    func testFailedStartClearsPendingFinishSoRetryRecords() async {
        let events = EventLog()
        let microphone = DelayedFailingMicrophone(events: events)
        let coordinator = DictationCoordinator(
            microphone: microphone, sttRouter: router(events: events), processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events), stopSpeech: {}, status: { _ in },
            activity: RecordingActivityOverlay()
        )
        let firstStart = Task { await coordinator.start() }
        await waitUntil { await microphone.didStart() }
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
            (TextInsertionError.accessibilityPermissionDenied, "Dictation failed: Allow Accessibility permission in System Settings before inserting dictation."),
            (TextInsertionError.emptyText, "Dictation failed: No speech was recognized. Try again.")
        ]
        for (error, expected) in cases {
            let events = EventLog()
            var statuses: [String] = []
            let coordinator = DictationCoordinator(
                microphone: FakeMicrophone(events: events), sttRouter: router(events: events, error: error as? SpeechBackendError),
                processor: RulesTranscriptProcessor(), textInserter: ErrorTextInserter(error: error), stopSpeech: {}, status: { statuses.append($0) },
                activity: RecordingActivityOverlay()
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
                stopSpeech: {}, status: { statuses.append($0) },
                activity: RecordingActivityOverlay()
            )
            await coordinator.start()
            XCTAssertEqual(statuses.last, "Could not start dictation: \(message)")
        }
    }

    // MARK: - Activity overlay: lifecycle, level, and cancellation

    func testDictationPublishesListeningProcessingAndCompletionForOneSession() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(overlay: overlay)
        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()
        XCTAssertEqual(
            overlay.events,
            [.listening(session), .backendName(session, "Fake"), .processing(session), .completed(session)]
        )
    }

    func testInteractiveCancelStopsOnlyMatchingListeningSession() async {
        let microphone = CancellableFakeMicrophone()
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(microphone: microphone, overlay: overlay)
        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.cancel(sessionID: session)
        XCTAssertEqual(microphone.cancelCount, 1)
        XCTAssertEqual(overlay.events.last, .cancelled(session))
    }

    func testCancelWithMismatchedSessionIDIsIgnored() async {
        let microphone = CancellableFakeMicrophone()
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(microphone: microphone, overlay: overlay)
        await coordinator.start()
        let session = overlay.sessionID!

        await coordinator.cancel(sessionID: UUID())

        XCTAssertEqual(microphone.cancelCount, 0)
        XCTAssertEqual(overlay.events, [.listening(session), .backendName(session, "Fake")])
    }

    /// The overlay must hide the instant `cancel(sessionID:)` is called, not once
    /// `microphone.cancel()` eventually finishes — otherwise a slow teardown would leave a stale
    /// capsule on screen.
    func testCancelPublishesOverlayCancelBeforeMicrophoneCancelCompletes() async {
        let microphone = CancellableFakeMicrophone(blockCancel: true)
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(microphone: microphone, overlay: overlay)
        await coordinator.start()
        let session = overlay.sessionID!

        let cancelTask = Task { await coordinator.cancel(sessionID: session) }
        await waitUntil { microphone.cancelCount == 1 }

        // `microphone.cancel()` is still blocked at this point; the overlay must already show
        // cancelled.
        XCTAssertEqual(overlay.events.last, .cancelled(session))

        microphone.releaseCancel()
        await cancelTask.value
    }

    /// While tearing down after a `cancel(sessionID:)` call, a hotkey-triggered `start()` must be
    /// silently dropped: no new `begin`/`listen` overlay events and no status change, since the
    /// coordinator isn't `.idle` yet.
    func testStartDuringCancellationTeardownIsSilentlyDropped() async {
        let microphone = CancellableFakeMicrophone(blockCancel: true)
        let overlay = RecordingActivityOverlay()
        var statuses: [String] = []
        let coordinator = makeCoordinator(microphone: microphone, status: { statuses.append($0) }, overlay: overlay)
        await coordinator.start()
        let session = overlay.sessionID!

        let cancelTask = Task { await coordinator.cancel(sessionID: session) }
        await waitUntil { microphone.cancelCount == 1 }
        statuses.removeAll()
        let eventsDuringTeardown = overlay.events

        await coordinator.start()

        XCTAssertEqual(overlay.events, eventsDuringTeardown)
        XCTAssertTrue(statuses.isEmpty)

        microphone.releaseCancel()
        await cancelTask.value

        // Once the teardown completes, a fresh start works normally.
        await coordinator.start()
        let newSession = overlay.sessionID!
        XCTAssertNotEqual(newSession, session)
        XCTAssertEqual(
            Array(overlay.events.suffix(2)),
            [.listening(newSession), .backendName(newSession, "Fake")]
        )
    }

    func testRecordingLevelUpdatesReachOverlayWhileListening() async {
        let microphone = LevelCapturingMicrophone()
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(microphone: microphone, overlay: overlay)

        await coordinator.start()
        await microphone.emitLevel(0.6)
        await Task.yield()

        XCTAssertEqual(overlay.levels, [0.6])
    }

    func testLateLevelUpdateForNoLongerRecordingSessionIsIgnored() async {
        let microphone = LevelCapturingMicrophone()
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(microphone: microphone, overlay: overlay)

        await coordinator.start()
        await coordinator.finish()
        await microphone.emitLevel(0.9)
        await Task.yield()

        XCTAssertTrue(overlay.levels.isEmpty)
    }

    func testCancelDuringFinishingCancelsProcessingTaskWithoutInserting() async {
        let backend = BlockingBackend()
        let sttRouter = STTRouter(backends: [backend.id: backend], backendOrder: { [backend.id] })
        let inserter = FakeTextInserter(events: EventLog())
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: sttRouter, textInserter: inserter, overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        let finishTask = Task { await coordinator.finish() }
        await waitUntil { backend.pendingCount >= 1 }

        await coordinator.cancel(sessionID: session)

        XCTAssertEqual(overlay.events.last, .cancelled(session))
        XCTAssertTrue(inserter.inserted.isEmpty)

        // Unblock the pipeline so the Task doesn't leak past the test.
        backend.resumeOldest(with: .success(Transcript(text: "hello", backendID: backend.id)))
        await finishTask.value
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testLateTranscriptionCompletionAfterCancelDoesNotInsertOrTouchOverlay() async {
        let backend = BlockingBackend()
        let sttRouter = STTRouter(backends: [backend.id: backend], backendOrder: { [backend.id] })
        let inserter = FakeTextInserter(events: EventLog())
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: sttRouter, textInserter: inserter, overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        let finishTask = Task { await coordinator.finish() }
        await waitUntil { backend.pendingCount >= 1 }
        await coordinator.cancel(sessionID: session)
        let eventsAfterCancel = overlay.events

        backend.resumeOldest(with: .success(Transcript(text: "hello", backendID: backend.id)))
        await finishTask.value

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(overlay.events, eventsAfterCancel)
    }

    /// Regression test: `finish()` used to clear `processingTask` unconditionally once its own
    /// task finished, even if that task belonged to an already-cancelled, older session. If a
    /// newer session's `finish()` had since replaced `processingTask`, the older session's
    /// completion would wipe out the reference the newer session's `cancel(sessionID:)` needs.
    func testCancelledFinishDoesNotClobberNextSessionsProcessingTask() async {
        let backend = BlockingBackend()
        let sttRouter = STTRouter(backends: [backend.id: backend], backendOrder: { [backend.id] })
        let inserter = FakeTextInserter(events: EventLog())
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: sttRouter, textInserter: inserter, overlay: overlay)

        await coordinator.start()
        let sessionA = overlay.sessionID!
        let finishA = Task { await coordinator.finish() }
        await waitUntil { backend.pendingCount >= 1 }

        await coordinator.cancel(sessionID: sessionA)

        await coordinator.start()
        let sessionB = overlay.sessionID!
        XCTAssertNotEqual(sessionA, sessionB)
        let finishB = Task { await coordinator.finish() }
        await waitUntil { backend.pendingCount >= 2 }

        // Let session A's (already-cancelled) transcription resolve and run its cleanup. With
        // the fix, this must not touch `processingTask`, which by now belongs to session B.
        backend.resumeOldest(with: .success(Transcript(text: "a", backendID: backend.id)))
        await finishA.value

        await coordinator.cancel(sessionID: sessionB)
        await Task.yield()

        // Both A's and B's underlying transcription calls must have been genuinely cancelled:
        // A directly by its own `cancel(sessionID:)`, and B only reachable if `processingTask`
        // still correctly referenced B's task (i.e. A's cleanup did not clobber it).
        XCTAssertEqual(backend.cancellationCount, 2)
        XCTAssertEqual(overlay.events.last, .cancelled(sessionB))

        // Unblock B's transcription so its Task doesn't leak past the test.
        backend.resumeOldest(with: .success(Transcript(text: "b", backendID: backend.id)))
        await finishB.value
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testListenPublishesThePreferredSTTBackendDisplayName() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!

        XCTAssertEqual(overlay.events, [.listening(session), .backendName(session, "Fake")])
    }

    func testFallbackDuringTranscriptionPublishesTheBackendThatActuallySucceeded() async {
        let events = EventLog()
        let first = NamedFakeBackend(id: "first", displayName: "First", events: events, error: .inferenceFailed("boom"))
        let second = NamedFakeBackend(id: "second", displayName: "Second", events: events)
        let sttRouter = STTRouter(backends: [first.id: first, second.id: second], backendOrder: { [first.id, second.id] })
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: sttRouter, overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()

        XCTAssertEqual(overlay.events, [
            .listening(session),
            .backendName(session, "First"),
            .processing(session),
            .backendName(session, "Second"),
            .completed(session),
        ])
    }

    func testMicrophoneStopThrowingNoUsableAudioReportsNoUsableAudioCategoryNotMicrophone() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(microphone: NoUsableAudioMicrophone(), overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()

        XCTAssertEqual(overlay.events.last, .failed(session, .noUsableAudio))
    }

    func testEmptyProcessedTranscriptReportsNoUsableAudioCategory() async {
        let overlay = RecordingActivityOverlay()
        let diagnostics = DiagnosticsRecorder()
        let coordinator = makeCoordinator(sttRouter: router(events: EventLog(), transcript: "   "), overlay: overlay, diagnostics: diagnostics)

        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()

        XCTAssertEqual(overlay.events.last, .failed(session, .noUsableAudio))
        // Leaves a trace so repeated no-speech results are visible in diagnostics, not just silently dropped.
        XCTAssertEqual(diagnostics.entries.last?.event, .dictation(.failed(.transcription)))
    }

    func testNoUsableAudioTranscriptionErrorReportsNoUsableAudioCategory() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: router(events: EventLog(), error: .noUsableAudio), overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()

        XCTAssertEqual(overlay.events.last, .failed(session, .noUsableAudio))
    }

    func testMicrophoneStartFailureReportsMicrophoneCategory() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = DictationCoordinator(
            microphone: ThrowingMicrophone(error: .unavailable("x")),
            sttRouter: router(events: EventLog()),
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: EventLog()),
            stopSpeech: {},
            status: { _ in },
            activity: overlay
        )

        await coordinator.start()

        XCTAssertEqual(overlay.events.last, .failed(overlay.sessionID!, .microphone))
    }

    func testTranscriptionFailureReportsSpeechRecognitionCategory() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: router(events: EventLog(), error: .inferenceFailed("x")), overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()

        XCTAssertEqual(overlay.events.last, .failed(session, .speechRecognition))
    }

    func testInsertionFailureReportsInsertionCategory() async {
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(textInserter: ErrorTextInserter(error: TextInsertionError.clipboardWriteFailed), overlay: overlay)

        await coordinator.start()
        let session = overlay.sessionID!
        await coordinator.finish()

        XCTAssertEqual(overlay.events.last, .failed(session, .insertion))
    }

    private func makeCoordinator(
        microphone: (any MicrophoneCapturing)? = nil,
        sttRouter: STTRouter? = nil,
        textInserter: (any TextInserting)? = nil,
        stopSpeech: @escaping () -> Void = {},
        status: @escaping (String) -> Void = { _ in },
        overlay: RecordingActivityOverlay,
        diagnostics: DiagnosticsRecorder? = nil
    ) -> DictationCoordinator {
        let events = EventLog()
        return DictationCoordinator(
            microphone: microphone ?? FakeMicrophone(events: events),
            sttRouter: sttRouter ?? router(events: events),
            processor: RulesTranscriptProcessor(),
            textInserter: textInserter ?? FakeTextInserter(events: events),
            stopSpeech: stopSpeech,
            status: status,
            activity: overlay,
            diagnostics: diagnostics
        )
    }

    private func router(events: EventLog, transcript: String = "text", error: SpeechBackendError? = nil) -> STTRouter {
        let backend = FakeBackend(events: events, transcript: transcript, error: error)
        return STTRouter(backends: [backend.id: backend], backendOrder: { [backend] in [backend.id] })
    }

    /// Polls `condition` (synchronous or async) until it returns `true`, or fails the test after
    /// `timeout` instead of hanging forever — used in place of an unbounded
    /// `while ... { await Task.yield() }` spin loop.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await condition() { return }
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

private actor DelayedFailingMicrophone: MicrophoneCapturing {
    let events: EventLog
    private var didInvokeStart = false
    private var attempts = 0
    private var started: CheckedContinuation<Void, Never>?
    init(events: EventLog) { self.events = events }
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {
        await events.append("microphone.start")
        attempts += 1
        didInvokeStart = true
        if attempts == 1 {
            await withCheckedContinuation { started = $0 }
            throw MicrophoneCaptureError.unavailable("x")
        }
    }
    func stop() async throws -> AudioInput { AudioInput(samples: [0.1], sampleRate: 16_000) }
    func cancel() async {}
    func didStart() -> Bool { didInvokeStart }
    func failStart() { started?.resume(); started = nil }
}

private struct ThrowingMicrophone: MicrophoneCapturing {
    let error: MicrophoneCaptureError
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws { throw error }
    func stop() async throws -> AudioInput { throw error }
    func cancel() async {}
}

/// A microphone whose `stop()` throws `SpeechBackendError.noUsableAudio` directly (as opposed to
/// a `MicrophoneCaptureError`), exercising the "no usable audio regardless of stage" mapping.
private struct NoUsableAudioMicrophone: MicrophoneCapturing {
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {}
    func stop() async throws -> AudioInput { throw SpeechBackendError.noUsableAudio }
    func cancel() async {}
}

/// A `@MainActor` fake satisfying `MicrophoneCapturing`'s `Sendable` refinement through its
/// global-actor isolation; every access here is already confined to the `@MainActor` test methods.
@MainActor
private final class CancellableFakeMicrophone: MicrophoneCapturing {
    private(set) var cancelCount = 0
    private let blockCancel: Bool
    private var cancelWaiter: CheckedContinuation<Void, Never>?

    init(blockCancel: Bool = false) {
        self.blockCancel = blockCancel
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {}
    func stop() async throws -> AudioInput { AudioInput(samples: [0.1], sampleRate: 16_000) }
    func cancel() async {
        cancelCount += 1
        if blockCancel {
            await withCheckedContinuation { cancelWaiter = $0 }
        }
    }
    func releaseCancel() {
        cancelWaiter?.resume()
        cancelWaiter = nil
    }
}

/// Captures the `onLevel` callback so a test can trigger level updates on demand.
private actor LevelCapturingMicrophone: MicrophoneCapturing {
    private var onLevel: (@Sendable (Float) -> Void)?
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {
        self.onLevel = onLevel
    }
    func stop() async throws -> AudioInput { AudioInput(samples: [0.1], sampleRate: 16_000) }
    func cancel() async { onLevel = nil }
    func emitLevel(_ level: Float) {
        onLevel?(level)
    }
}

@MainActor
private final class ErrorTextInserter: TextInserting {
    let error: Error
    init(error: Error) { self.error = error }
    func insert(_ text: String) throws -> TextInsertionMechanism { throw error }
}

@MainActor
private final class EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor FakeMicrophone: MicrophoneCapturing {
    let events: EventLog
    init(events: EventLog) { self.events = events }
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws { await events.append("microphone.start") }
    func stop() async throws -> AudioInput { await events.append("microphone.stop"); return AudioInput(samples: [0.1], sampleRate: 16_000) }
    func cancel() async { await events.append("microphone.cancel") }
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

/// Like `FakeBackend`, but with a configurable `id`/`displayName` so tests can exercise a
/// multi-backend `STTRouter` fallback and verify which backend's display name is published.
@MainActor
private final class NamedFakeBackend: SpeechToTextBackend {
    let id: String
    let displayName: String
    let capabilities = STTCapabilities([])
    let events: EventLog
    let transcript: String
    let error: SpeechBackendError?
    init(id: String, displayName: String, events: EventLog, transcript: String = "text", error: SpeechBackendError? = nil) {
        self.id = id
        self.displayName = displayName
        self.events = events
        self.transcript = transcript
        self.error = error
    }
    func availability() async -> BackendAvailability { .available }
    func prepare() async throws {}
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        events.append("stt.transcribe.\(id)")
        if let error { throw error }
        return Transcript(text: transcript, backendID: id)
    }
}

/// A backend whose `transcribe` calls each suspend (FIFO) until explicitly released, so tests can
/// observe coordinator behavior while a transcription stage is still in flight — including
/// multiple overlapping calls across sessions, and whether the calling `Task` was genuinely
/// cancelled while suspended (via `withTaskCancellationHandler`, which fires promptly even though
/// the continuation itself never resumes on its own).
private final class BlockingBackend: SpeechToTextBackend, @unchecked Sendable {
    let id = "blocking"
    let displayName = "Blocking"
    let capabilities = STTCapabilities([])
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Transcript, Error>] = []
    private var cancellations = 0

    func availability() async -> BackendAvailability { .available }
    func prepare() async throws {}

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending.append(continuation) }
            }
        } onCancel: { [self] in
            lock.withLock { cancellations += 1 }
        }
    }

    /// Resumes the oldest still-pending `transcribe` call (FIFO), simulating multiple sessions'
    /// calls being in flight against this one backend.
    func resumeOldest(with result: Result<Transcript, Error>) {
        let continuation: CheckedContinuation<Transcript, Error>? = lock.withLock {
            pending.isEmpty ? nil : pending.removeFirst()
        }
        continuation?.resume(with: result)
    }

    var pendingCount: Int { lock.withLock { pending.count } }
    var cancellationCount: Int { lock.withLock { cancellations } }
}

/// A backend whose `availability()` blocks on its very first call until `release()` is invoked,
/// then answers immediately on every later call. Simulates a `preferredBackendDisplayName()`
/// lookup that's still in flight when a concurrent `finish()` reaches its own (separate)
/// `transcribe()`-driven availability check on the same backend.
private final class BlockingAvailabilityBackend: SpeechToTextBackend, @unchecked Sendable {
    let id = "blocking-availability"
    let displayName = "Blocking Availability"
    let capabilities = STTCapabilities([])
    private let lock = NSLock()
    private var callCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func availability() async -> BackendAvailability {
        let isFirstCall: Bool = lock.withLock {
            callCount += 1
            return callCount == 1
        }
        if isFirstCall {
            await withCheckedContinuation { continuation in
                lock.withLock { waiter = continuation }
            }
        }
        return .available
    }

    func prepare() async throws {}

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        Transcript(text: "hello relay", backendID: id)
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        continuation?.resume()
    }
}

@MainActor
private final class FakeTextInserter: TextInserting {
    let events: EventLog
    let mechanism: TextInsertionMechanism
    private(set) var inserted: [String] = []
    init(events: EventLog, mechanism: TextInsertionMechanism = .accessibility) {
        self.events = events
        self.mechanism = mechanism
    }
    func insert(_ text: String) throws -> TextInsertionMechanism {
        inserted.append(text)
        events.append("insert")
        return mechanism
    }
}

/// Records the events `DictationCoordinator` publishes through the `DictationActivityPublishing`
/// seam, mirroring `ActivityOverlayModel`'s state transitions without needing the real model.
@MainActor
private final class RecordingActivityOverlay: DictationActivityPublishing {
    enum Event: Equatable {
        case listening(UUID)
        case processing(UUID)
        case completed(UUID)
        case cancelled(UUID)
        case failed(UUID, ActivityOverlayErrorCategory)
        case backendName(UUID, String)
    }

    private(set) var sessionID: UUID?
    private(set) var events: [Event] = []
    private(set) var levels: [Float] = []
    private let trace: EventLog?

    init(trace: EventLog? = nil) {
        self.trace = trace
    }

    func begin(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func listen(sessionID: UUID, startedAt: Date) {
        events.append(.listening(sessionID))
        trace?.append("overlay.listen")
    }

    func updateLevel(_ level: Float, sessionID: UUID) {
        levels.append(level)
    }

    func setBackendName(_ name: String, sessionID: UUID) {
        events.append(.backendName(sessionID, name))
    }

    func process(sessionID: UUID) {
        events.append(.processing(sessionID))
    }

    func complete(sessionID: UUID) {
        events.append(.completed(sessionID))
    }

    func cancel(sessionID: UUID) {
        events.append(.cancelled(sessionID))
    }

    func fail(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String) {
        events.append(.failed(sessionID, category))
    }
}
