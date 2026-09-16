import Foundation

/// The seam `DictationCoordinator` publishes lifecycle, level, and cancellation events through.
/// Mirrors the corresponding `ActivityOverlayModel` API so the model can conform via a bare
/// extension; a test fake can record events without touching the model itself.
@MainActor
protocol DictationActivityPublishing: AnyObject {
    func begin(sessionID: UUID)
    func listen(sessionID: UUID, startedAt: Date)
    func updateLevel(_ level: Float, sessionID: UUID)
    /// SPIKE: live, best-effort transcription text (see StreamingTranscriber). Display-only.
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
    /// Reads the frontmost app immediately before microphone capture starts, so it can be
    /// recorded as supporting evidence of a recent voice interaction. Best-effort only: `start()`
    /// never lets a failure or delay here affect dictation itself.
    private let frontmostApps: any FrontmostAppMonitoring
    /// Memory-only record of the most recent voice interaction's frontmost app. Supporting
    /// evidence only — no resolver consumes it yet, and it must never independently produce a
    /// `focused(high)` result.
    private let recentInteractions: RecentInteractionTracker
    private var status: (String) -> Void
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
    /// SPIKE: live, best-effort interim transcription for the pill (see StreamingTranscriber).
    /// Created fresh per session in `start()`, torn down in `stopStreamingTranscription()`.
    private var streamingTranscriber: StreamingTranscriber?

    init(
        microphone: any MicrophoneCapturing,
        sttRouter: STTRouter,
        processor: RulesTranscriptProcessor,
        textInserter: any TextInserting,
        stopSpeech: @escaping () -> Void,
        status: @escaping (String) -> Void,
        activity: any DictationActivityPublishing,
        diagnostics: DiagnosticsRecorder? = nil,
        frontmostApps: any FrontmostAppMonitoring = FrontmostAppMonitor(),
        recentInteractions: RecentInteractionTracker = RecentInteractionTracker()
    ) {
        self.microphone = microphone
        self.sttRouter = sttRouter
        self.processor = processor
        self.textInserter = textInserter
        self.stopSpeech = stopSpeech
        self.status = status
        self.activity = activity
        self.diagnostics = diagnostics
        self.frontmostApps = frontmostApps
        self.recentInteractions = recentInteractions
    }

    func setStatusHandler(_ handler: @escaping (String) -> Void) { status = handler }

    func start() async {
        guard case .idle = state else { return }
        let session = UUID()
        state = .starting(session)
        activity.begin(sessionID: session)
        stopSpeech()
        // Best-effort: recording the frontmost app is supporting evidence only. A `nil` result is
        // simply skipped, and nothing here can block, delay, or fail dictation itself.
        if let frontmostApplication = await frontmostApps.current() {
            await recentInteractions.record(frontmostApplication: frontmostApplication)
        }
        // SPIKE: must be wired up before microphone.start(onLevel:) below - see
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
        if let name = await sttRouter.preferredBackendDisplayName(), isRecording(session) {
            announcedBackendName = name
            activity.setBackendName(name, sessionID: session)
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
        await stopStreamingTranscription()

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
        if case .idle = state { await start() }
        else { await finish() }
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

    /// SPIKE: creates a fresh `StreamingTranscriber` for this session, wires it up as the
    /// microphone's sample observer (if the concrete `microphone` supports the optional
    /// `MicrophoneSampleStreaming` capability), and kicks off its (best-effort, backgrounded)
    /// model load. Must run before `microphone.start(onLevel:)` — see that protocol doc comment.
    private func beginStreamingTranscription(session: UUID) async {
        // No point loading a streaming session (real CoreML models, real disk access) when there
        // is no way to feed it samples. This also keeps every test fake that does not implement
        // MicrophoneSampleStreaming (i.e. all of them, deliberately) from ever touching FluidAudio.
        guard let streaming = microphone as? any MicrophoneSampleStreaming else { return }
        let transcriber = StreamingTranscriber { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording(session) else { return }
                self.activity.updateInterimText(text, sessionID: session)
            }
        }
        streamingTranscriber = transcriber
        await streaming.setSampleObserver { samples in
            Task { await transcriber.appendSamples(samples) }
        }
        Task { await transcriber.start() }
    }


    /// SPIKE: tears down this session's `StreamingTranscriber` (if any) and detaches it from the
    /// microphone's sample observer, so a stale observer never forwards a later session's samples
    /// to an actor nobody is reading interim text from anymore.
    private func stopStreamingTranscription() async {
        guard let transcriber = streamingTranscriber else { return }
        streamingTranscriber = nil
        if let streaming = microphone as? any MicrophoneSampleStreaming {
            await streaming.setSampleObserver(nil)
        }
        await transcriber.stop()
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
            transcript = try await sttRouter.transcribe(audio: audio, options: .init())
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
        status("Dictation failed: \(actionableMessage(for: error))")
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

    private func actionableMessage(for error: Error) -> String {
        switch error {
        case SpeechBackendError.unavailable:
            "Speech recognition is unavailable. Try again after it is ready."
        case SpeechBackendError.modelNotDownloaded:
            "Download the Apple Speech assets, then try again."
        case SpeechBackendError.initializationFailed:
            "Speech recognition could not start. Try again."
        case SpeechBackendError.unsupportedOS:
            "Apple Speech requires a newer version of macOS."
        case SpeechBackendError.unsupportedHardware:
            "Apple Speech is unavailable on this Mac."
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
