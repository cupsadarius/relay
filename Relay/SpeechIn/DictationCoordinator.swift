import Foundation

/// The seam `DictationCoordinator` publishes lifecycle, level, and cancellation events through.
/// Mirrors the corresponding `ActivityOverlayModel` API so the model can conform via a bare
/// extension; a test fake can record events without touching the model itself.
@MainActor
protocol DictationActivityPublishing: AnyObject {
    func begin(sessionID: UUID)
    func listen(sessionID: UUID, startedAt: Date)
    func updateLevel(_ level: Float, sessionID: UUID)
    func process(sessionID: UUID)
    func complete(sessionID: UUID)
    func cancel(sessionID: UUID)
    func fail(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String)
}

@MainActor
protocol DictationCoordinating: AnyObject {
    func start() async
    func finish() async
    /// No-op unless `sessionID` matches the session currently starting, recording, or finishing.
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
    }

    private let microphone: any MicrophoneCapturing
    private let sttRouter: STTRouter
    private let processor: RulesTranscriptProcessor
    private let textInserter: any TextInserting
    private let stopSpeech: () -> Void
    private let activity: any DictationActivityPublishing
    private let diagnostics: DiagnosticsRecorder?
    private var status: (String) -> Void
    private var state: State = .idle
    private var finishRequested = false
    private var processingTask: Task<Void, Never>?

    init(
        microphone: any MicrophoneCapturing,
        sttRouter: STTRouter,
        processor: RulesTranscriptProcessor,
        textInserter: any TextInserting,
        stopSpeech: @escaping () -> Void,
        status: @escaping (String) -> Void,
        activity: any DictationActivityPublishing,
        diagnostics: DiagnosticsRecorder? = nil
    ) {
        self.microphone = microphone
        self.sttRouter = sttRouter
        self.processor = processor
        self.textInserter = textInserter
        self.stopSpeech = stopSpeech
        self.status = status
        self.activity = activity
        self.diagnostics = diagnostics
    }

    func setStatusHandler(_ handler: @escaping (String) -> Void) { status = handler }

    func start() async {
        guard case .idle = state else { return }
        let session = UUID()
        state = .starting(session)
        activity.begin(sessionID: session)
        stopSpeech()
        do {
            try await microphone.start(onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.isRecording(session) else { return }
                    self.activity.updateLevel(level, sessionID: session)
                }
            })
        } catch {
            guard isStarting(session) else { return }
            state = .idle
            finishRequested = false
            diagnostics?.record(.dictation(.failed(.microphoneCapture)))
            activity.fail(sessionID: session, category: .microphone, message: "Microphone error.")
            status("Could not start dictation: \(actionableMessage(for: error))")
            return
        }

        guard isStarting(session) else { return }
        state = .recording(session)
        activity.listen(sessionID: session, startedAt: .now)
        status("Listening…")
        diagnostics?.record(.dictation(.listening))
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

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingPipeline(session: session)
        }
        processingTask = task
        await task.value
        processingTask = nil
    }

    func toggle() async {
        if case .idle = state { await start() }
        else { await finish() }
    }

    func cancel(sessionID: UUID) async {
        if isStarting(sessionID) || isRecording(sessionID) {
            state = .idle
            finishRequested = false
            await microphone.cancel()
            activity.cancel(sessionID: sessionID)
        } else if isFinishing(sessionID) {
            processingTask?.cancel()
            processingTask = nil
            state = .idle
            await microphone.cancel()
            activity.cancel(sessionID: sessionID)
        }
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
        let text = processor.process(transcript.text)
        guard !text.isEmpty else {
            state = .idle
            activity.fail(sessionID: session, category: .noUsableAudio, message: "No speech was recognized.")
            status("No speech was recognized. Try again.")
            return
        }

        do {
            let mechanism = try textInserter.insert(text)
            guard !Task.isCancelled, isFinishing(session) else { return }
            state = .idle
            diagnostics?.record(.dictation(.inserted(mechanism)))
            activity.complete(sessionID: session)
            status("Inserted dictation")
        } catch {
            guard !Task.isCancelled, isFinishing(session) else { return }
            fail(error, at: .insertion, session: session)
        }
    }

    private func fail(_ error: Error, at stage: DictationFailureStage, session: UUID) {
        state = .idle
        diagnostics?.record(.dictation(.failed(stage)))
        activity.fail(sessionID: session, category: category(for: error, stage: stage), message: capsuleMessage(for: stage, error: error))
        status("Dictation failed: \(actionableMessage(for: error))")
    }

    private func category(for error: Error, stage: DictationFailureStage) -> ActivityOverlayErrorCategory {
        switch stage {
        case .microphoneCapture:
            return .microphone
        case .insertion:
            return .insertion
        case .transcription:
            if case SpeechBackendError.noUsableAudio = error { return .noUsableAudio }
            return error is SpeechBackendError ? .speechRecognition : .unexpected
        }
    }

    private func capsuleMessage(for stage: DictationFailureStage, error: Error) -> String {
        switch stage {
        case .microphoneCapture:
            return "Microphone error."
        case .insertion:
            return "Could not insert text."
        case .transcription:
            if case SpeechBackendError.noUsableAudio = error { return "No speech was recognized." }
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
