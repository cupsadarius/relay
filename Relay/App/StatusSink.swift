import Observation

/// The single owner of Relay's transient, user-facing status line (the menu bar's idle text).
/// Created first in `RelayRuntime.makeProduction()` and handed to every writer — `AppModel`, its
/// sub-models, and `DictationCoordinator` — at construction time, so nothing is re-pointed after
/// `AppModel` exists.
@MainActor
@Observable
final class StatusSink {
    static let idleMessage = "Ready"

    private(set) var message: String

    init(message: String = StatusSink.idleMessage) {
        self.message = message
    }

    func post(_ message: String) {
        self.message = message
    }
}
