import Foundation

enum SpeechBackendError: Error, Equatable, Sendable {
    case unavailable(String)
    case modelNotDownloaded
    case initializationFailed(String)
    case unsupportedHardware
    case inferenceFailed(String)
    case resourceExhausted
    case permissionDenied
    case noUsableAudio
    case invalidInput

    var isFallbackWorthy: Bool {
        switch self {
        case .unavailable, .modelNotDownloaded, .initializationFailed,
            .unsupportedHardware, .inferenceFailed,
            .resourceExhausted:
            true
        case .permissionDenied, .noUsableAudio, .invalidInput:
            false
        }
    }
}
