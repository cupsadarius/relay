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
        case starting(UUID)
        case recording(UUID)
        case finishing(UUID)
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
    private let activity: any DictationActivityPublishing
    private let diagnostics: DiagnosticsRecorder?
    private let status: (String) -> Void
    private var state: State = .idle
    private var finishRequested = false
    private var processingTask: Task<Void, Never>?
    /// The session `processingTask` belongs to. `finish()` only clears `processingTask` on its
    /// own completion if this still matches the session it started with — otherwise a later
    /// session's `finish()` has since replaced it, and clobbering it would leave that newer
    /// session's task unreachable from `cancel(sessionID:)`.
    private var processingSession: UUID?
    /// The STT backend display name announced to the overlay when listening began, so a later
    /// fallback to a different backend during transcription can be detected and re-announced.
    private var announcedBackendName: String?
    /// The backend chosen when listening began. `finish()` passes it to the final transcription,
    /// so backends ruled out at listen time are not probed again.
    private var sttSelection: STTSelection?
    /// Live, best-effort interim transcription for the pill (see StreamingTranscriber).
    /// Created fresh per session in `start()`, torn down in `stopStreamingTranscription()` (joining
    /// teardown: cancel/start's failure path) or `abandonStreamingTranscription()` (non-joining
    /// teardown: `finish()`, which must never wait on it).
    private var streamingTranscriber: StreamingTranscriber?
    /// Read once per `start()` to decide whether to start a `StreamingTranscriber`.
    private let liveTranscriptionEnabled: () -> Bool
    /// Drains `sampleAppendStream` one batch at a time, in arrival order, into
    /// `streamingTranscriber`. Created fresh per session in `beginStreamingTranscription`, torn
    /// down in `stopStreamingTranscription` or `abandonStreamingTranscription` (see those methods).
    private var sampleAppendTask: Task<Void, Never>?
    /// Keeps sample batches in microphone order; a `Task` per batch would not.
    private var sampleAppendContinuation: AsyncStream<[Float]>.Continuation?

    init(
        microphone: any MicrophoneCapturing,
        sttRouter: STTRouter,
        processor: RulesTranscriptProcessor,
        textInserter: any TextInserting,
        stopSpeech: @escaping () -> Void,
        status: @escaping (String) -> Void,
        activity: any DictationActivityPublishing,
        diagnostics: DiagnosticsRecorder? = nil,
        liveTranscriptionEnabled: @escaping () -> Bool = { true }
    ) {
        self.microphone = microphone
        self.sttRouter = sttRouter
        self.processor = processor
        self.textInserter = textInserter
        self.stopSpeech = stopSpeech
        self.status = status
        self.activity = activity
        self.diagnostics = diagnostics
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
    }

    func start() async {
        guard case .idle = state else { return }
        let session = UUID()
        state = .starting(session)
        activity.begin(sessionID: session)
        stopSpeech()
        // Must run before microphone.start(onLevel:); see setSampleObserver.
        await beginStreamingTranscription(session: session)
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
            guard isStarting(session) else { return }
            state = .idle
            finishRequested = false
            await stopStreamingTranscription()
            diagnostics?.record(.dictation(.failed(.microphoneCapture)))
            let failure = DictationFailure(error, stage: .microphoneCapture)
            activity.fail(sessionID: session, category: failure.category, message: failure.capsuleMessage)
            status("Could not start dictation: \(failure.statusMessage)")
            return
        }

        guard isStarting(session) else { return }
        state = .recording(session)
        activity.listen(sessionID: session, startedAt: .now)
        // Recorded here, before the `await` below, so nothing can interleave between them: a
        // concurrent `finish()` admitted during the backend-name lookup's suspension could
        // otherwise run the entire processing pipeline to completion first, landing this stale
        // "Listening…" status and diagnostic after the session's own "Inserted dictation".
        status("Listening…")
        diagnostics?.record(.dictation(.listening))
        announcedBackendName = nil
        sttSelection = nil
        if let selection = await sttRouter.selectBackend(), isRecording(session) {
            sttSelection = selection
            announcedBackendName = selection.displayName
            activity.setBackendName(selection.displayName, sessionID: session)
        }
        if finishRequested {
            finishRequested = false
            await finish()
        }
    }

    func finish() async {
        if case .starting = state {
            finishRequested = true
            return
        }
        guard case let .recording(session) = state else { return }
        state = .finishing(session)
        activity.process(sessionID: session)
        // Non-joining: the final transcript must never wait on interim work.
        abandonStreamingTranscription()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingPipeline(session: session)
        }
        processingTask = task
        processingSession = session
        await task.value
        if processingSession == session {
            processingTask = nil
            processingSession = nil
        }
    }

    func toggle() async {
        if case .idle = state { await start() } else { await finish() }
    }

    /// No-op unless `sessionID` is currently starting, recording, or finishing — in particular,
    /// a second `cancel(sessionID:)` call for a session already `.cancelling` does nothing.
    func cancel(sessionID: UUID) async {
        guard isStarting(sessionID) || isRecording(sessionID) || isFinishing(sessionID) else { return }
        if isFinishing(sessionID) {
            processingTask?.cancel()
            processingTask = nil
            processingSession = nil
        }
        finishRequested = false
        sttSelection = nil
        state = .cancelling(sessionID)
        // Published before awaiting `microphone.cancel()` so the capsule hides instantly, and so
        // a `start()` admitted mid-teardown (which the `.cancelling` state above already blocks)
        // can never race this cancel out from under the overlay's own session guard.
        activity.cancel(sessionID: sessionID)
        await stopStreamingTranscription()
        await microphone.cancel()
        state = .idle
        status("Ready")
    }

    private func isStarting(_ session: UUID) -> Bool {
        if case let .starting(id) = state { return id == session }
        return false
    }

    private func isRecording(_ session: UUID) -> Bool {
        if case let .recording(id) = state { return id == session }
        return false
    }

    private func isFinishing(_ session: UUID) -> Bool {
        if case let .finishing(id) = state { return id == session }
        return false
    }

    /// Creates a fresh `StreamingTranscriber` for this session, wires it up as the
    /// microphone's sample observer, and starts its periodic re-transcribe loop. Must
    /// run before `microphone.start(onLevel:)` — see `setSampleObserver`.
    private func beginStreamingTranscription(session: UUID) async {
        guard liveTranscriptionEnabled() else { return }

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
        streamingTranscriber = transcriber

        let (sampleStream, sampleContinuation) = AsyncStream.makeStream(of: [Float].self)
        sampleAppendContinuation = sampleContinuation
        sampleAppendTask = Task {
            for await samples in sampleStream {
                await transcriber.appendSamples(samples)
            }
        }
        await microphone.setSampleObserver { samples in
            sampleContinuation.yield(samples)
        }
        await transcriber.start()
    }

    /// Tears down this session's `StreamingTranscriber` (if any) and detaches it from the
    /// microphone's sample observer, so a stale observer never forwards a later session's samples
    /// to an actor nobody is reading interim text from anymore.
    /// Joining: can wait on an in-flight interim call, so `finish()` must not use it.
    private func stopStreamingTranscription() async {
        guard let transcriber = streamingTranscriber else { return }
        streamingTranscriber = nil
        await microphone.setSampleObserver(nil)
        sampleAppendContinuation?.finish()
        sampleAppendContinuation = nil
        await sampleAppendTask?.value
        sampleAppendTask = nil
        await transcriber.stop()
    }

    /// Non-joining teardown for `finish()`. The final transcript uses the microphone's own full
    /// buffer, and a late interim result is dropped by both `tick()` and the recording guard.
    private func abandonStreamingTranscription() {
        guard let transcriber = streamingTranscriber else { return }
        streamingTranscriber = nil
        Task { [microphone] in await microphone.setSampleObserver(nil) }
        sampleAppendContinuation?.finish()
        sampleAppendContinuation = nil
        sampleAppendTask = nil
        Task { await transcriber.abandon() }
    }

    private func runProcessingPipeline(session: UUID) async {
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
            let selection = sttSelection
            sttSelection = nil
            transcript = try await sttRouter.transcribe(audio: audio, options: .init(), selection: selection)
        } catch {
            guard !Task.isCancelled, isFinishing(session) else { return }
            fail(error, at: .transcription, session: session)
            return
        }

        guard !Task.isCancelled, isFinishing(session) else { return }
        let usedName = transcript.backendID.displayName
        if usedName != announcedBackendName {
            announcedBackendName = usedName
            activity.setBackendName(usedName, sessionID: session)
        }
        let text = processor.process(transcript.text)
        guard !text.isEmpty else {
            state = .idle
            diagnostics?.record(.dictation(.failed(.transcription)))
            activity.fail(sessionID: session, category: .noUsableAudio, message: DictationFailure.noSpeechCapsuleMessage)
            status(DictationFailure.noSpeechStatusMessage)
            return
        }

        // No suspension point since the guard above, so a concurrent cancel() cannot interleave.
        do {
            let mechanism = try textInserter.insert(text)
            state = .idle
            diagnostics?.record(.dictation(.inserted(mechanism)))
            activity.complete(sessionID: session)
            status("Inserted dictation")
        } catch {
            fail(error, at: .insertion, session: session)
        }
    }

    private func fail(_ error: Error, at stage: DictationFailureStage, session: UUID) {
        state = .idle
        diagnostics?.record(.dictation(.failed(stage)))
        // Only a transcription-stage error came from a speech backend; name the one that failed.
        let backendName = stage == .transcription ? sttRouter.lastFailedBackendDisplayName : nil
        let failure = DictationFailure(error, stage: stage, backendName: backendName)
        activity.fail(sessionID: session, category: failure.category, message: failure.capsuleMessage)
        status("Dictation failed: \(failure.statusMessage)")
    }
}
