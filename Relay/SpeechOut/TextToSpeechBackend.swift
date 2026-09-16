import Foundation

enum TTSPlaybackEvent: Equatable, Sendable {
    case scheduled(sessionID: UUID)
    case started(sessionID: UUID)
    case level(sessionID: UUID, level: Float)
    case finished(sessionID: UUID)
    case cancelled(sessionID: UUID)
    case failed(sessionID: UUID)

    var sessionID: UUID {
        switch self {
        case let .scheduled(sessionID),
             let .started(sessionID),
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
    var capabilities: TTSCapabilities { get }

    func availability() async -> BackendAvailability
    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void)
    /// Validates `text`/`options`, starts (or schedules) playback, and RETURNS as soon as
    /// playback has started - it never waits for playback to finish. Progress and completion are
    /// reported asynchronously afterward through the handler installed via
    /// `setPlaybackEventHandler(_:)`, as the event sequence `scheduled -> started -> level* ->`
    /// exactly one of `finished | cancelled | failed`. Every conforming backend returns from
    /// `speak` at that same lifecycle point (playback started) regardless of how differently each
    /// one gets there internally - a backend that cannot start playback at all THROWS instead (so
    /// `TTSRouter` can fall back to the next backend) and emits no terminal event of its own.
    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}
