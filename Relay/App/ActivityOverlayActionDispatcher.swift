import Foundation

/// The AppKit-independent seam the activity overlay panel's Interactive-style buttons dispatch
/// through. Kept free of any backend- or AppKit-specific logic: it only routes an action to the
/// coordinator that owns the represented session.
@MainActor
protocol ActivityOverlayControlling: AnyObject {
    func perform(_ action: ActivityOverlayAction)
}

/// Routes overlay button taps to the dictation and speech coordinators. Holds weak references so
/// it never keeps either coordinator alive on its own, and never references the window controller
/// or `AppModel` that retains it.
@MainActor
final class ActivityOverlayActionDispatcher: ActivityOverlayControlling {
    private weak var dictation: (any DictationCoordinating)?
    private weak var speech: (any SpeechCoordinating)?

    init(dictation: any DictationCoordinating, speech: any SpeechCoordinating) {
        self.dictation = dictation
        self.speech = speech
    }

    func perform(_ action: ActivityOverlayAction) {
        switch action {
        case let .cancelDictation(sessionID):
            let dictation = dictation
            Task { await dictation?.cancel(sessionID: sessionID) }
        case let .stopSpeech(sessionID):
            speech?.stop(sessionID: sessionID)
        }
    }
}
