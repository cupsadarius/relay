import Foundation

/// The seam `DictationCoordinator` publishes lifecycle, level, and cancellation events through.
/// Mirrors the corresponding `ActivityOverlayModel` API so the model can conform via a bare
/// extension; a test fake can record events without touching the model itself.
@MainActor
protocol DictationActivityPublishing: AnyObject {
    func begin(sessionID: UUID)
    func listen(sessionID: UUID, startedAt: Date)
    func updateLevel(_ level: Float, sessionID: UUID)
    /// Live, best-effort transcription text (see StreamingTranscriber). Display-only.
    func updateInterimText(_ text: String, sessionID: UUID)
    func setBackendName(_ name: String, sessionID: UUID)
    func process(sessionID: UUID)
    func complete(sessionID: UUID)
    func cancel(sessionID: UUID)
    func fail(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String)
}

@MainActor
protocol DictationCoordinating: AnyObject {
    func start() async
    func finish() async
    func cancel(sessionID: UUID) async
    func toggle() async
}

@MainActor
final class DictationCoordinator: DictationCoordinating {
    private enum State {
        case idle
        /// `finishRequested`: `finish()` arrived before recording began; it runs once recording does.
        case starting(UUID, live: LiveTranscription?, finishRequested: Bool)
        /// `stt`: the backend chosen when listening began. The final transcription reuses it, so
        /// backends ruled out at listen time are not probed again.
        case recording(UUID, live: LiveTranscription?, stt: STTSelection?)
        case finishing(UUID, processing: Task<Void, Never>)
        /// Tearing down after a `cancel(sessionID:)` call: the overlay has already been told to
        /// hide, and `microphone.cancel()` is in flight. `start()`'s `.idle` guard refuses a
        /// hotkey press admitted during this window, so it's silently dropped rather than
        /// racing the in-progress teardown.
        case cancelling(UUID)
    }

    private let microphone: any MicrophoneCapturing
    private let sttRouter: STTRouter
    private let processor: RulesTranscriptProcessor
    private let textInserter: any TextInserting
    private let stopSpeech: () -> Void
    /// `true` while a dictation runs, `false` when it ends, so automatic speech waits for it.
    private let holdSpeech: (Bool) -> Void
    private let activity: any DictationActivityPublishing
    private let diagnostics: DiagnosticsRecorder?
    private let pipeline: PipelineEventBus?
    /// Announces the current or last run; a new one per `start()`.
    private var tracer: PipelineTracer?
    private let status: (String) -> Void
    private var state: State = .idle {
        didSet {
            let wasIdle = if case .idle = oldValue { true } else { false }
            let isIdle = if case .idle = state { true } else { false }
            if wasIdle != isIdle { holdSpeech(!isIdle) }
        }
    }
    /// Read once per `start()` to decide whether to start a `LiveTranscription`.
    private let liveTranscriptionEnabled: () -> Bool

    init(
        microphone: any MicrophoneCapturing,
        sttRouter: STTRouter,
        processor: RulesTranscriptProcessor,
        textInserter: any TextInserting,
        stopSpeech: @escaping () -> Void,
        holdSpeech: @escaping (Bool) -> Void = { _ in },
        status: @escaping (String) -> Void,
        activity: any DictationActivityPublishing,
        diagnostics: DiagnosticsRecorder? = nil,
        pipeline: PipelineEventBus? = nil,
        liveTranscriptionEnabled: @escaping () -> Bool = { true }
    ) {
        self.pipeline = pipeline
        self.microphone = microphone
        self.sttRouter = sttRouter
        self.processor = processor
        self.textInserter = textInserter
        self.stopSpeech = stopSpeech
        self.holdSpeech = holdSpeech
        self.status = status
        self.activity = activity
        self.diagnostics = diagnostics
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
    }

    func start() async {
        guard case .idle = state else { return }
        let session = UUID()
        let live = liveTranscriptionEnabled() ? makeLiveTranscription(session: session) : nil
        state = .starting(session, live: live, finishRequested: false)
        let tracer = pipeline.map { PipelineTracer(flow: .dictation, bus: $0, runID: session) }
        self.tracer = tracer
        tracer?.finish(.hotkey, "Pressed")
        await microphone.setTracer(tracer)
        activity.begin(sessionID: session)
        stopSpeech()
        // Must run before microphone.start(onLevel:); see setSampleObserver.
        await live?.start()
        // A cancel during `live.start()` already ran `stop()`, which this start then undid.
        guard case let .starting(id, _, _) = state, id == session else {
            await live?.stop()
            return
        }
        do {
            try await microphone.start(onLevel: { [weak self] level in
                // Each level batch hops to the main actor via its own `Task`, so relative
                // ordering between rapid batches isn't guaranteed. That's acceptable for a
                // meter, which only ever needs a recent value, not a precise sequence.
                Task { @MainActor in
                    guard let self, self.isRecording(session) else { return }
                    self.activity.updateLevel(level, sessionID: session)
                }
            })
        } catch {
            guard case let .starting(id, live, _) = state, id == session else { return }
            state = .idle
            await live?.stop()
            diagnostics?.record(.dictation(.failed(.microphoneCapture)))
            let failure = DictationFailure(error, stage: .microphoneCapture)
            activity.fail(sessionID: session, category: failure.category, message: failure.capsuleMessage)
            status("Could not start dictation: \(failure.statusMessage)")
            return
        }

        guard case let .starting(id, live, finishRequested) = state, id == session else { return }
        state = .recording(session, live: live, stt: nil)
        activity.listen(sessionID: session, startedAt: .now)
        // Recorded here, before the `await` below, so nothing can interleave between them: a
        // concurrent `finish()` admitted during the backend-name lookup's suspension could
        // otherwise run the entire processing pipeline to completion first, landing this stale
        // "Listening…" status and diagnostic after the session's own "Inserted dictation".
        status("Listening…")
        diagnostics?.record(.dictation(.listening))
        if let selection = await sttRouter.selectBackend(), case let .recording(id, live, _) = state, id == session {
            state = .recording(session, live: live, stt: selection)
            activity.setBackendName(selection.displayName, sessionID: session)
        }
        if finishRequested, isRecording(session) {
            await finish()
        }
    }

    func finish() async {
        switch state {
        case let .starting(session, live, _):
            state = .starting(session, live: live, finishRequested: true)
        case let .recording(session, live, selection):
            activity.process(sessionID: session)
            // Non-joining: the final transcript must never wait on interim work.
            live?.abandon()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runProcessingPipeline(session: session, selection: selection)
            }
            state = .finishing(session, processing: task)
            await task.value
        case .idle, .finishing, .cancelling:
            return
        }
    }

    func toggle() async {
        if case .idle = state { await start() } else { await finish() }
    }

    /// No-op unless `sessionID` is currently starting, recording, or finishing — in particular,
    /// a second `cancel(sessionID:)` call for a session already `.cancelling` does nothing.
    func cancel(sessionID: UUID) async {
        let live: LiveTranscription?
        switch state {
        case let .starting(id, starting, _) where id == sessionID:
            live = starting
        case let .recording(id, recording, _) where id == sessionID:
            live = recording
        case let .finishing(id, processing) where id == sessionID:
            processing.cancel()
            live = nil
        default:
            return
        }
        state = .cancelling(sessionID)
        // Published before awaiting `microphone.cancel()` so the capsule hides instantly, and so
        // a `start()` admitted mid-teardown (which the `.cancelling` state above already blocks)
        // can never race this cancel out from under the overlay's own session guard.
        activity.cancel(sessionID: sessionID)
        await live?.stop()
        await microphone.cancel()
        state = .idle
        status("Ready")
    }

    private func isRecording(_ session: UUID) -> Bool {
        if case let .recording(id, _, _) = state { return id == session }
        return false
    }

    private func isFinishing(_ session: UUID) -> Bool {
        if case let .finishing(id, _) = state { return id == session }
        return false
    }

    private func makeLiveTranscription(session: UUID) -> LiveTranscription {
        let transcriber = StreamingTranscriber(
            transcribe: { [sttRouter] audio in
                try await sttRouter.transcribeForInterim(audio: audio, options: .init())
            },
            onInterimText: { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording(session) else { return }
                    self.activity.updateInterimText(text, sessionID: session)
                }
            }
        )
        return LiveTranscription(microphone: microphone, transcriber: transcriber)
    }

    private func runProcessingPipeline(session: UUID, selection: STTSelection?) async {
        guard isFinishing(session) else { return }

        let audio: AudioInput
        do {
            audio = try await microphone.stop()
        } catch {
            guard !Task.isCancelled, isFinishing(session) else { return }
            fail(error, at: .microphoneCapture, session: session)
            return
        }

        guard !Task.isCancelled, isFinishing(session) else { return }
        diagnostics?.record(.dictation(.processing))

        let transcript: Transcript
        do {
            transcript = try await sttRouter.transcribe(audio: audio, options: .init(), selection: selection, tracer: tracer)
        } catch {
            guard !Task.isCancelled, isFinishing(session) else { return }
            fail(error, at: .transcription, session: session)
            return
        }

        guard !Task.isCancelled, isFinishing(session) else { return }
        let usedName = transcript.backendID.displayName
        if usedName != selection?.displayName {
            activity.setBackendName(usedName, sessionID: session)
        }
        let text = processor.process(transcript.text)
        guard !text.isEmpty else {
            tracer?.stop(.cleanUp, "No speech")
            state = .idle
            diagnostics?.record(.dictation(.failed(.transcription)))
            activity.fail(sessionID: session, category: .noUsableAudio, message: DictationFailure.noSpeechCapsuleMessage)
            status(DictationFailure.noSpeechStatusMessage)
            return
        }

        let removed = Self.wordCount(transcript.text) - Self.wordCount(text)
        tracer?.finish(.cleanUp, removed > 0 ? "Removed \(removed) word\(removed == 1 ? "" : "s")" : "Nothing to remove")

        // No suspension point since the guard above, so a concurrent cancel() cannot interleave.
        do {
            let mechanism = try textInserter.insert(text)
            tracer?.finish(.insert, mechanism == .paste ? "Pasted" : "Inserted via Accessibility")
            state = .idle
            diagnostics?.record(.dictation(.inserted(mechanism)))
            activity.complete(sessionID: session)
            status("Inserted dictation")
        } catch {
            fail(error, at: .insertion, session: session)
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func fail(_ error: Error, at stage: DictationFailureStage, session: UUID) {
        state = .idle
        if stage == .insertion { tracer?.fail(.insert, "Could not insert the text") }
        diagnostics?.record(.dictation(.failed(stage)))
        // Only a transcription-stage error came from a speech backend; name the one that failed.
        let backendName = stage == .transcription ? sttRouter.lastFailedBackendDisplayName : nil
        let failure = DictationFailure(error, stage: stage, backendName: backendName)
        activity.fail(sessionID: session, category: failure.category, message: failure.capsuleMessage)
        status("Dictation failed: \(failure.statusMessage)")
    }
}

/// Live, best-effort interim transcription for the pill (see StreamingTranscriber). One per session;
/// whoever takes it out of the coordinator's state ends it with `stop()` or `abandon()`.
@MainActor
private struct LiveTranscription {
    private let microphone: any MicrophoneCapturing
    private let transcriber: StreamingTranscriber
    /// Keeps sample batches in microphone order; a `Task` per batch would not.
    private let samples: AsyncStream<[Float]>.Continuation
    private let appendTask: Task<Void, Never>

    init(microphone: any MicrophoneCapturing, transcriber: StreamingTranscriber) {
        self.microphone = microphone
        self.transcriber = transcriber
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        samples = continuation
        appendTask = Task {
            for await batch in stream {
                await transcriber.appendSamples(batch)
            }
        }
    }

    /// Must run before `microphone.start(onLevel:)`; see `setSampleObserver`.
    func start() async {
        await microphone.setSampleObserver { [samples] batch in
            samples.yield(batch)
        }
        await transcriber.start()
    }

    /// Joining: can wait on an in-flight interim call, so `finish()` must not use it.
    func stop() async {
        await microphone.setSampleObserver(nil)
        samples.finish()
        await appendTask.value
        await transcriber.stop()
    }

    /// Non-joining teardown for `finish()`. The final transcript uses the microphone's own full
    /// buffer, and a late interim result is dropped by both `tick()` and the recording guard.
    func abandon() {
        Task { [microphone] in await microphone.setSampleObserver(nil) }
        samples.finish()
        Task { [transcriber] in await transcriber.abandon() }
    }
}
