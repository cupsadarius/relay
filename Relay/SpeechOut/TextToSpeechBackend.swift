import Foundation

enum TTSPlaybackEvent: Equatable, Sendable {
    case started(sessionID: UUID)
    case level(sessionID: UUID, level: Float)
    case finished(sessionID: UUID)
    case cancelled(sessionID: UUID)
    case failed(sessionID: UUID)

    var sessionID: UUID {
        switch self {
        case let .started(sessionID),
            let .finished(sessionID),
            let .cancelled(sessionID),
            let .failed(sessionID):
            sessionID
        case let .level(sessionID, _):
            sessionID
        }
    }
}

@MainActor
protocol TextToSpeechBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }

    func availability() async -> BackendAvailability

    /// Prepares the backend (loading a local model without downloading, validating voice/options)
    /// and returns a provider-neutral `TTSAudioSource` that produces the utterance's PCM on demand.
    /// The backend does NOT own playback: `TTSRouter` drives one shared `StreamingAudioPlayer` with
    /// the returned source. Throwing here (before any audio has started) lets the router fall back
    /// to the next backend; a failure that surfaces later, mid-stream, is reported by the shared
    /// player as `.failed` for the committed session and never triggers fallback.
    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource
}
