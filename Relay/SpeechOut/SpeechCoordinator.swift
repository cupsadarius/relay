import Foundation

@MainActor
protocol SpeechCoordinating: AnyObject {
    func speak(_ request: SpeechRequest) async throws
    func stop()
    func stop(sessionID: UUID)
    func replayLast() async throws
}

/// A narrow submission-only view of `SpeechCoordinating`, used by callers (like
/// `AgentAutoReadCoordinator`) that only ever need to submit a `SpeechRequest` and have no
/// business stopping or replaying speech.
@MainActor
protocol SpeechSubmitting: AnyObject {
    func speak(_ request: SpeechRequest) async throws
}

/// `@unchecked Sendable`: every stored property is mutated only from `@MainActor`-isolated
/// methods, so cross-isolation callers (e.g. `AgentAutoReadCoordinator`, an `actor`) can safely
/// hold this behind `any SpeechSubmitting & Sendable` and `await` into it — the actor isolation
/// itself, not the compiler's Sendable check, is what actually serializes access here.
extension SpeechCoordinator: SpeechSubmitting, @unchecked Sendable {}

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
        router.setPlaybackEventHandler { [weak self] event, backend in
            self?.handle(event, backend: backend)
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
            overlay.prepareSpeaking(sessionID: sessionID)
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
        if let overlaySessionID = overlay.state.sessionID, overlaySessionID != currentSessionID {
            overlay.cancel(sessionID: overlaySessionID)
        }
        currentSessionID = nil
        pendingAutomaticSessions.removeAll()
    }

    /// No-ops for a stale (already-replaced) session ID; otherwise stops the
    /// router and hides only the matching overlay session.
    func stop(sessionID: UUID) {
        guard router.stop(sessionID: sessionID) else { return }
        overlay.cancel(sessionID: sessionID)
        if currentSessionID == sessionID {
            currentSessionID = nil
        }
        pendingAutomaticSessions.remove(sessionID)
    }

    func replayLast() async throws {
        guard let lastRequest else { return }

        router.stop()
        let sessionID = UUID()
        currentSessionID = sessionID
        overlay.begin(sessionID: sessionID)
        overlay.prepareSpeaking(sessionID: sessionID)

        try await router.speak(text: lastRequest.text, options: options(), sessionID: sessionID)
    }

    private func handle(_ event: TTSPlaybackEvent, backend: (any TextToSpeechBackend)?) {
        switch event {
        case .scheduled:
            break
        case let .started(sessionID):
            if pendingAutomaticSessions.remove(sessionID) != nil {
                overlay.begin(sessionID: sessionID)
            }
            overlay.speak(sessionID: sessionID)
            if let backend {
                overlay.setBackendName(backend.displayName, sessionID: sessionID)
            }
        case let .level(sessionID, level):
            overlay.updateSpeakingLevel(level, sessionID: sessionID)
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
