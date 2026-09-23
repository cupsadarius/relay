import Foundation

/// Routes the overlay panel's Interactive-style buttons to the coordinator that owns the session.
/// Free of AppKit and backend logic; the panel awaits it directly.
@MainActor
enum ActivityOverlayActions {
    static func perform(
        _ action: ActivityOverlayAction,
        dictation: (any DictationCoordinating)?,
        speech: any SpeechCoordinating
    ) async {
        switch action {
        case let .cancelDictation(sessionID):
            await dictation?.cancel(sessionID: sessionID)
        case let .stopSpeech(sessionID):
            speech.stop(sessionID: sessionID)
        }
    }
}
