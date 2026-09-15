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
    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}
