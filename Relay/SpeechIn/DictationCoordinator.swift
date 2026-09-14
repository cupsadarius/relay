import Foundation

@MainActor
protocol DictationCoordinating: AnyObject {
    func start() async
    func finish() async
    func toggle() async
}

@MainActor
final class DictationCoordinator: DictationCoordinating {
    private enum State { case idle, starting, recording, finishing }

    private let microphone: any MicrophoneCapturing
    private let sttRouter: STTRouter
    private let processor: RulesTranscriptProcessor
    private let textInserter: any TextInserting
    private let stopSpeech: () -> Void
    private let diagnostics: DiagnosticsRecorder?
    private var status: (String) -> Void
    private var state: State = .idle
    private var finishRequested = false

    init(
        microphone: any MicrophoneCapturing,
        sttRouter: STTRouter,
        processor: RulesTranscriptProcessor,
        textInserter: any TextInserting,
        stopSpeech: @escaping () -> Void,
        status: @escaping (String) -> Void,
        diagnostics: DiagnosticsRecorder? = nil
    ) {
        self.microphone = microphone
        self.sttRouter = sttRouter
        self.processor = processor
        self.textInserter = textInserter
        self.stopSpeech = stopSpeech
        self.status = status
        self.diagnostics = diagnostics
    }

    func setStatusHandler(_ handler: @escaping (String) -> Void) { status = handler }

    func start() async {
        guard case .idle = state else { return }
        state = .starting
        stopSpeech()
        do {
            try await microphone.start()
            state = .recording
            status("Listening…")
            diagnostics?.record(.dictation(.listening))
            if finishRequested {
                finishRequested = false
                await finish()
            }
        } catch {
            state = .idle
            finishRequested = false
            diagnostics?.record(.dictation(.failed(.microphoneCapture)))
            status("Could not start dictation: \(actionableMessage(for: error))")
        }
    }

    func finish() async {
        if case .starting = state {
            finishRequested = true
            return
        }
        guard case .recording = state else { return }
        state = .finishing
        let audio: AudioInput
        do {
            audio = try await microphone.stop()
        } catch {
            fail(error, at: .microphoneCapture)
            return
        }
        diagnostics?.record(.dictation(.processing))
        let transcript: Transcript
        do {
            transcript = try await sttRouter.transcribe(audio: audio, options: .init())
        } catch {
            fail(error, at: .transcription)
            return
        }
        let text = processor.process(transcript.text)
        guard !text.isEmpty else {
            state = .idle
            status("No speech was recognized. Try again.")
            return
        }
        do {
            try textInserter.insert(text)
            state = .idle
            diagnostics?.record(.dictation(.inserted))
            status("Inserted dictation")
        } catch {
            fail(error, at: .insertion)
        }
    }

    func toggle() async {
        if case .idle = state { await start() }
        else { await finish() }
    }

    private func fail(_ error: Error, at stage: DictationFailureStage) {
        state = .idle
        diagnostics?.record(.dictation(.failed(stage)))
        status("Dictation failed: \(actionableMessage(for: error))")
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
        default:
            "An unexpected error occurred. Try again."
        }
    }
}
