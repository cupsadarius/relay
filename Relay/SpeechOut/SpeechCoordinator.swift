import Foundation

@MainActor
protocol SpeechCoordinating: AnyObject {
    func speak(_ request: SpeechRequest) async throws
    func stop()
    func stop(sessionID: UUID)
    func replayLast() async throws
}

@MainActor
final class SpeechCoordinator: SpeechCoordinating {
    private let router: TTSRouter
    private let options: () -> TTSOptions
    private let overlay: ActivityOverlayModel
    private var lastRequest: SpeechRequest?
    private var currentSessionID: UUID?
    /// Automatic-mode sessions that have not yet been shown in the overlay.
    /// Showing them only once playback actually starts (or fails) avoids
    /// hiding the capsule for whatever is still speaking when an automatic
    /// request is merely queued behind it.
    private var pendingAutomaticSessions: Set<UUID> = []

    init(router: TTSRouter, options: @escaping () -> TTSOptions, overlay: ActivityOverlayModel) {
        self.router = router
        self.options = options
        self.overlay = overlay
        router.setPlaybackEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    func speak(_ request: SpeechRequest) async throws {
        if request.mode == .userRequested {
            router.stop()
        }

        let sessionID = UUID()
        currentSessionID = sessionID

        switch request.mode {
        case .userRequested:
            overlay.begin(sessionID: sessionID)
        case .automatic:
            pendingAutomaticSessions.insert(sessionID)
        }

        try await router.speak(text: request.text, options: options(), sessionID: sessionID)
        lastRequest = request
    }

    func stop() {
        router.stop()
        if let currentSessionID {
            overlay.cancel(sessionID: currentSessionID)
        }
        currentSessionID = nil
    }

    /// No-ops for a stale (already-replaced) session ID; otherwise stops the
    /// router and hides only the matching overlay session.
    func stop(sessionID: UUID) {
        router.stop(sessionID: sessionID)
        overlay.cancel(sessionID: sessionID)
        if currentSessionID == sessionID {
            currentSessionID = nil
        }
    }

    func replayLast() async throws {
        guard let lastRequest else { return }

        router.stop()
        let sessionID = UUID()
        currentSessionID = sessionID
        overlay.begin(sessionID: sessionID)

        try await router.speak(text: lastRequest.text, options: options(), sessionID: sessionID)
    }

    private func handle(_ event: TTSPlaybackEvent) {
        switch event {
        case .scheduled:
            break
        case let .started(sessionID):
            if pendingAutomaticSessions.remove(sessionID) != nil {
                overlay.begin(sessionID: sessionID)
            }
            overlay.speak(sessionID: sessionID)
        case let .finished(sessionID):
            // A pending automatic session that never started was never
            // shown in the overlay; nothing to complete.
            guard pendingAutomaticSessions.remove(sessionID) == nil else { return }
            overlay.complete(sessionID: sessionID)
        case let .cancelled(sessionID):
            guard pendingAutomaticSessions.remove(sessionID) == nil else { return }
            overlay.cancel(sessionID: sessionID)
        case let .failed(sessionID):
            if pendingAutomaticSessions.remove(sessionID) != nil {
                overlay.begin(sessionID: sessionID)
            }
            overlay.fail(sessionID: sessionID, category: .speechPlayback, message: "Speech playback failed.")
        }
    }
}
