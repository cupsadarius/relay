import Foundation
import Observation

enum ActivityOverlayErrorCategory: Equatable, Sendable {
    case microphone
    case speechRecognition
    case noUsableAudio
    case speechPlayback
    case insertion
    case unexpected
}

enum ActivityOverlayState: Equatable, Sendable {
    case hidden
    case listening(sessionID: UUID, startedAt: Date, level: Float, interimText: String = "")
    case processing(sessionID: UUID, startedAt: Date)
    case preparingSpeech(sessionID: UUID, startedAt: Date)
    case speaking(sessionID: UUID, startedAt: Date, level: Float?)
    case error(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String)

    var sessionID: UUID? {
        switch self {
        case .hidden:
            nil
        case let .listening(sessionID, _, _, _),
            let .processing(sessionID, _),
            let .preparingSpeech(sessionID, _),
            let .speaking(sessionID, _, _),
            let .error(sessionID, _, _):
            sessionID
        }
    }

    var isHidden: Bool {
        if case .hidden = self { true } else { false }
    }

    var action: ActivityOverlayAction? {
        switch self {
        case let .listening(sessionID, _, _, _), let .processing(sessionID, _):
            .cancelDictation(sessionID: sessionID)
        case let .preparingSpeech(sessionID, _), let .speaking(sessionID, _, _):
            .stopSpeech(sessionID: sessionID)
        case .hidden, .error:
            nil
        }
    }
}

enum ActivityOverlayAction: Equatable, Sendable {
    case cancelDictation(sessionID: UUID)
    case stopSpeech(sessionID: UUID)
}

@MainActor
protocol ActivityOverlayScheduling {
    func schedule(after: Duration, _ operation: @escaping @MainActor () -> Void)
}

@MainActor
struct MainActorOverlayScheduler: ActivityOverlayScheduling {
    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            operation()
        }
    }
}

@MainActor
@Observable
final class ActivityOverlayModel {
    private(set) var state: ActivityOverlayState = .hidden
    private(set) var backendName: String?
    @ObservationIgnored private let scheduler: any ActivityOverlayScheduling
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var terminalGeneration = 0
    @ObservationIgnored private var isCompleting = false
    @ObservationIgnored private var stateDidChange: (@MainActor (ActivityOverlayState) -> Void)?

    init(scheduler: any ActivityOverlayScheduling = MainActorOverlayScheduler()) {
        self.scheduler = scheduler
    }

    func setStateHandler(_ handler: @escaping @MainActor (ActivityOverlayState) -> Void) {
        stateDidChange = handler
        handler(state)
    }

    func begin(sessionID: UUID) {
        terminalGeneration += 1
        activeSessionID = sessionID
        isCompleting = false
        setState(.hidden)
    }

    func listen(sessionID: UUID, startedAt: Date = .now) {
        guard activeSessionID == sessionID else { return }
        setState(.listening(sessionID: sessionID, startedAt: startedAt, level: 0))
    }

    func updateLevel(_ level: Float, sessionID: UUID) {
        guard case let .listening(activeSessionID, startedAt, _, interimText) = state,
            activeSessionID == sessionID
        else { return }
        setState(
            .listening(
                sessionID: sessionID, startedAt: startedAt, level: min(max(level, 0), 1), interimText: interimText))
    }

    /// Pushes a live, best-effort transcription update (see StreamingTranscriber) into the
    /// pill while still listening. A no-op once the session has moved past listening (e.g. into
    /// processing) so a late update racing the stop of dictation cannot resurrect stale text.
    func updateInterimText(_ text: String, sessionID: UUID) {
        guard case let .listening(activeSessionID, startedAt, level, _) = state,
            activeSessionID == sessionID
        else { return }
        setState(.listening(sessionID: sessionID, startedAt: startedAt, level: level, interimText: text))
    }

    func process(sessionID: UUID) {
        guard case let .listening(activeSessionID, startedAt, _, _) = state,
            activeSessionID == sessionID
        else { return }
        setState(.processing(sessionID: sessionID, startedAt: startedAt))
    }

    /// Shows the amber "Processing" pill immediately for user-requested speech, before synthesis
    /// has produced any audio to play. `speak(sessionID:)` transitions this to the Speaking
    /// waveform once playback actually starts.
    func prepareSpeaking(sessionID: UUID, startedAt: Date = .now) {
        guard activeSessionID == sessionID else { return }
        setState(.preparingSpeech(sessionID: sessionID, startedAt: startedAt))
    }

    func speak(sessionID: UUID, startedAt: Date = .now) {
        guard activeSessionID == sessionID else { return }
        setState(.speaking(sessionID: sessionID, startedAt: startedAt, level: nil))
    }

    func updateSpeakingLevel(_ level: Float, sessionID: UUID) {
        guard case let .speaking(activeID, startedAt, _) = state,
            activeID == sessionID
        else { return }
        setState(.speaking(sessionID: sessionID, startedAt: startedAt, level: min(max(level, 0), 1)))
    }

    func setBackendName(_ name: String, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        backendName = name
    }

    func complete(sessionID: UUID) {
        guard activeSessionID == sessionID, !isCompleting else { return }
        isCompleting = true
        terminalGeneration += 1
        let generation = terminalGeneration
        scheduler.schedule(after: .milliseconds(180)) { [weak self] in
            guard self?.activeSessionID == sessionID,
                self?.isCompleting == true,
                self?.terminalGeneration == generation
            else { return }
            self?.activeSessionID = nil
            self?.isCompleting = false
            self?.setState(.hidden)
        }
    }

    func cancel(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        terminalGeneration += 1
        activeSessionID = nil
        isCompleting = false
        setState(.hidden)
    }

    func fail(sessionID: UUID, category: ActivityOverlayErrorCategory, message: String) {
        guard activeSessionID == sessionID, !isCompleting else { return }
        terminalGeneration += 1
        let generation = terminalGeneration
        setState(.error(sessionID: sessionID, category: category, message: message))
        scheduler.schedule(after: .milliseconds(2_500)) { [weak self] in
            guard self?.activeSessionID == sessionID,
                self?.terminalGeneration == generation
            else { return }
            self?.activeSessionID = nil
            self?.isCompleting = false
            self?.setState(.hidden)
        }
    }

    private func setState(_ nextState: ActivityOverlayState) {
        state = nextState
        if case .hidden = nextState { backendName = nil }
        stateDidChange?(nextState)
    }
}

/// No behavior change: `ActivityOverlayModel` already implements every method
/// `DictationActivityPublishing` requires with matching signatures.
extension ActivityOverlayModel: DictationActivityPublishing {}

extension ActivityOverlayState {
    /// The menu-bar line for this state; `idle` is shown when nothing is happening.
    func menuStatusText(idle: String) -> String {
        switch self {
        case .listening: "Listening…"
        case .processing: "Transcribing…"
        case .preparingSpeech: "Processing…"
        case .speaking: "Speaking…"
        case let .error(_, _, message): message
        case .hidden: idle
        }
    }
}
