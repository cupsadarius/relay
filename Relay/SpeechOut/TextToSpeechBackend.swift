import AVFoundation
import Foundation

enum TTSPlaybackEvent: Equatable, Sendable {
    case scheduled(sessionID: UUID)
    case started(sessionID: UUID)
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

/// Seam over `AVSpeechSynthesizer` so tests can drive playback lifecycle
/// without speaking through the real system voice.
@MainActor
protocol AppleSpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: AppleSpeechSynthesizing {}
