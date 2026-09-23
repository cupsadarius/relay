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
    /// Read once per `start()` to decide whether to spin up a `StreamingTranscriber` at all.
    /// Defaults to always-on so every existing test and call site that doesn't care about the
    /// setting keeps behaving exactly as before.
    private let liveTranscriptionEnabled: () -> Bool
    /// Drains `sampleAppendStream` one batch at a time, in arrival order, into
    /// `streamingTranscriber`. Created fresh per session in `beginStreamingTranscription`, torn
    /// down in `stopStreamingTranscription` or `abandonStreamingTranscription` (see those methods).
    private var sampleAppendTask: Task<Void, Never>?
    /// Lets the microphone's (non-async, arbitrary-context) sample callback enqueue a batch
    /// without racing other batches: `yield` is synchronous and thread-safe, so every batch lands
    /// in the stream in the exact order the microphone produced it, and `sampleAppendTask`'s
    /// single `for await` loop appends them to the actor one at a time in that same order -
    /// unlike spawning a new unstructured `Task` per batch, whose relative scheduling order the
    /// runtime does not guarantee.
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
        // Must be wired up before microphone.start(onLevel:) below - see
        // MicrophoneSampleStreaming doc comment for why. Best-effort: if microphone does not
        // implement the (optional) sample-streaming capability, dictation proceeds exactly as
        // before, just without a live interim transcript.
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
            activity.fail(sessionID: session, category: .microphone, message: "Microphone error.")
            status("Could not start dictation: \(actionableMessage(for: error))")
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
        // NON-JOINING on purpose: the final transcript below must never wait on disposable interim
        // work. See `abandonStreamingTranscription()`'s doc comment for why this is safe -- the
        // audio the final transcript is built from comes from `microphone.stop()`'s own,
        // independent accumulator, not from anything `stopStreamingTranscription()` would have
        // flushed.
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
    /// microphone's sample observer (if the concrete `microphone` supports the optional
    /// `MicrophoneSampleStreaming` capability), and starts its periodic re-transcribe loop. Must
    /// run before `microphone.start(onLevel:)` — see that protocol's doc comment.
    private func beginStreamingTranscription(session: UUID) async {
        // Settings-gated: when live transcription is off this is a full no-op below - no timer,
        // no interim transcribes, no sample observer - so dictation behaves exactly as before.
        guard liveTranscriptionEnabled() else { return }
        // No point starting an interim session when there is no way to feed it samples. This also
        // keeps every test fake that does not implement MicrophoneSampleStreaming (i.e. all of
        // them, deliberately) from ever touching sttRouter for anything beyond the final batch call.
        guard let streaming = microphone as? any MicrophoneSampleStreaming else { return }

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
        await streaming.setSampleObserver { samples in
            sampleContinuation.yield(samples)
        }
        await transcriber.start()
    }

    /// Tears down this session's `StreamingTranscriber` (if any) and detaches it from the
    /// microphone's sample observer, so a stale observer never forwards a later session's samples
    /// to an actor nobody is reading interim text from anymore.
    ///
    /// JOINING: awaits both the sample-drain task and `transcriber.stop()`, so this can block on
    /// an in-flight interim `transcribe(...)` call (see `StreamingTranscriber.stop()`'s doc
    /// comment). That's acceptable for callers doing a clean, non-time-critical teardown (`cancel`
    /// and `start()`'s own failure path), but `finish()` must NOT use this -- see
    /// `abandonStreamingTranscription()` below.
    private func stopStreamingTranscription() async {
        guard let transcriber = streamingTranscriber else { return }
        streamingTranscriber = nil
        if let streaming = microphone as? any MicrophoneSampleStreaming {
            await streaming.setSampleObserver(nil)
        }
        sampleAppendContinuation?.finish()
        sampleAppendContinuation = nil
        await sampleAppendTask?.value
        sampleAppendTask = nil
        await transcriber.stop()
    }

    /// `finish()`'s non-joining counterpart to `stopStreamingTranscription()` above. Detaches
    /// this session's `StreamingTranscriber` from the coordinator and lets it tear itself down in
    /// the background, WITHOUT awaiting any of it -- so this method itself never suspends, and
    /// `finish()` can proceed straight to building the final-transcription pipeline immediately.
    ///
    /// Safe to do because the final transcript never depends on anything this would otherwise
    /// await: the sample-drain task only ever feeds `streamingTranscriber`'s own interim buffer
    /// (capped to the rolling `maxWindowSamples` window), never the audio the final transcript is
    /// built from -- that comes from `microphone.stop()`'s separate, full, uncapped accumulator in
    /// `runProcessingPipeline`. So nothing here needs to finish before the final pipeline starts;
    /// detaching the sample observer just stops feeding a transcriber that's about to be abandoned,
    /// and it's fire-and-forget for the same reason nothing downstream needs to observe it landing.
    ///
    /// The interim actor's in-flight `transcribe(...)` call (if any) is left running to completion
    /// in the background by `StreamingTranscriber.abandon()` -- seeing it through, rather than
    /// somehow force-killing it, is what keeps the shared FluidAudio Parakeet actor consistent for
    /// the final transcribe that follows. If that shared actor can only run one call at a time,
    /// the final transcribe may still have to wait for the actor to become AVAILABLE again, but it
    /// never waits on the abandoned call's RESULT: `abandon()`'s cancellation makes
    /// `StreamingTranscriber.tick()` discard that result once it does arrive (see its
    /// `Task.isCancelled` check), and independently, this session's `onInterimText` closure is
    /// itself guarded on `isRecording(session)` in `beginStreamingTranscription` -- by the time
    /// any stale interim result could arrive, `state` has already moved past `.recording`, so it's
    /// dropped there too. Either guard alone is enough for a late interim result to never reach
    /// the overlay, let alone overwrite the authoritative final text.
    private func abandonStreamingTranscription() {
        guard let transcriber = streamingTranscriber else { return }
        streamingTranscriber = nil
        if let streaming = microphone as? any MicrophoneSampleStreaming {
            Task { await streaming.setSampleObserver(nil) }
        }
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
        if let usedName = sttRouter.displayName(forBackendID: transcript.backendID), usedName != announcedBackendName {
            announcedBackendName = usedName
            activity.setBackendName(usedName, sessionID: session)
        }
        let text = processor.process(transcript.text)
        guard !text.isEmpty else {
            state = .idle
            diagnostics?.record(.dictation(.failed(.transcription)))
            activity.fail(sessionID: session, category: .noUsableAudio, message: "No speech was recognized.")
            status("No speech was recognized. Try again.")
            return
        }

        // `textInserter.insert` is synchronous with no suspension point after the guard above,
        // so once started it can't be interrupted by a concurrent cancel(); there's nothing to
        // re-check before applying its result.
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
        activity.fail(sessionID: session, category: category(for: error, stage: stage), message: capsuleMessage(for: stage, error: error))
        // Only a transcription-stage error came from a speech backend; name the one that failed.
        let backendName = stage == .transcription ? sttRouter.lastFailedBackendDisplayName : nil
        status("Dictation failed: \(actionableMessage(for: error, backendName: backendName))")
    }

    /// `SpeechBackendError.noUsableAudio` always means "no usable audio", regardless of which
    /// stage surfaced it (the microphone itself can throw it from `stop()`, not just the STT
    /// backend from `transcribe()`), so it's checked before the per-stage mapping below.
    private func category(for error: Error, stage: DictationFailureStage) -> ActivityOverlayErrorCategory {
        if case SpeechBackendError.noUsableAudio = error { return .noUsableAudio }
        switch stage {
        case .microphoneCapture:
            return .microphone
        case .insertion:
            return .insertion
        case .transcription:
            return error is SpeechBackendError ? .speechRecognition : .unexpected
        }
    }

    private func capsuleMessage(for stage: DictationFailureStage, error: Error) -> String {
        if case SpeechBackendError.noUsableAudio = error { return "No speech was recognized." }
        switch stage {
        case .microphoneCapture:
            return "Microphone error."
        case .insertion:
            return "Could not insert text."
        case .transcription:
            return "Speech recognition failed."
        }
    }

    /// `backendName` is the display name of the speech backend that produced `error`, when
    /// known (see `STTRouter.lastFailedBackendDisplayName`). Never hardcode one backend here.
    private func actionableMessage(for error: Error, backendName: String? = nil) -> String {
        switch error {
        case SpeechBackendError.unavailable:
            "Speech recognition is unavailable. Try again after it is ready."
        case SpeechBackendError.modelNotDownloaded:
            backendName.map { "Download the \($0) model in Settings, then try again." }
                ?? "Download a speech recognition model in Settings, then try again."
        case SpeechBackendError.initializationFailed:
            "Speech recognition could not start. Try again."
        case SpeechBackendError.unsupportedOS:
            "\(backendName ?? "This speech recognition backend") requires a newer version of macOS."
        case SpeechBackendError.unsupportedHardware:
            "\(backendName ?? "This speech recognition backend") is unavailable on this Mac."
        case SpeechBackendError.inferenceFailed:
            "Speech recognition could not understand the audio. Try again."
        case SpeechBackendError.resourceExhausted:
            "Speech recognition is busy. Try again shortly."
        case SpeechBackendError.permissionDenied:
            "Allow Microphone permission in System Settings, then try again."
        case SpeechBackendError.noUsableAudio:
            "No usable audio was captured. Check your microphone and try again."
        case SpeechBackendError.invalidInput:
            "The recorded audio was invalid. Try again."
        case MicrophoneCaptureError.unavailable:
            "Microphone is unavailable. Check its connection and permissions."
        case MicrophoneCaptureError.alreadyRecording:
            "Microphone recording is already in progress. Try again shortly."
        case MicrophoneCaptureError.notRecording:
            "Microphone recording was interrupted. Try again."
        case TextInsertionError.clipboardWriteFailed:
            "Relay could not insert text. Grant Accessibility permission and try again."
        case TextInsertionError.accessibilityPermissionDenied:
            "Allow Accessibility permission in System Settings before inserting dictation."
        case TextInsertionError.emptyText:
            "No speech was recognized. Try again."
        default:
            "An unexpected error occurred. Try again."
        }
    }
}
