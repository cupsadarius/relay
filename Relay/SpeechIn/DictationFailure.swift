import Foundation

/// What the overlay and the status line say about one dictation error.
struct DictationFailure: Equatable {
    static let noSpeechCapsuleMessage = "No speech was recognized."
    static let noSpeechStatusMessage = "No speech was recognized. Try again."

    let category: ActivityOverlayErrorCategory
    let capsuleMessage: String
    let statusMessage: String

    /// `backendName` is the speech backend that produced `error`, when known.
    init(_ error: Error, stage: DictationFailureStage, backendName: String? = nil) {
        // `noUsableAudio` means the same thing at every stage; the microphone can throw it too.
        if case SpeechBackendError.noUsableAudio = error {
            category = .noUsableAudio
            capsuleMessage = Self.noSpeechCapsuleMessage
        } else {
            switch stage {
            case .microphoneCapture:
                category = .microphone
                capsuleMessage = "Microphone error."
            case .insertion:
                category = .insertion
                capsuleMessage = "Could not insert text."
            case .transcription:
                category = error is SpeechBackendError ? .speechRecognition : .unexpected
                capsuleMessage = "Speech recognition failed."
            }
        }
        statusMessage = Self.statusMessage(for: error, backendName: backendName)
    }

    private static func statusMessage(for error: Error, backendName: String?) -> String {
        switch error {
        case SpeechBackendError.unavailable:
            "Speech recognition is unavailable. Try again after it is ready."
        case SpeechBackendError.modelNotDownloaded:
            backendName.map { "Download the \($0) model in Settings, then try again." }
                ?? "Download a speech recognition model in Settings, then try again."
        case SpeechBackendError.initializationFailed:
            "Speech recognition could not start. Try again."
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
            noSpeechStatusMessage
        default:
            "An unexpected error occurred. Try again."
        }
    }
}
