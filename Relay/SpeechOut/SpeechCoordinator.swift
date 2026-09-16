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
    /// Most-recent automatic requests are kept when the queue overflows; older ones are dropped
    /// first so a long silent backlog can never build up behind whatever is currently playing.
    private static let queueCap = 8

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
    /// `true` from the moment a request is actually handed to the router until a terminal
    /// playback event (`.finished`/`.cancelled`/`.failed`) is observed for it. While `true`, a
    /// new `.automatic` request is enqueued rather than overlapping the one in flight.
    private var isSpeaking = false
    /// FIFO backlog of `.automatic` requests waiting for the current one to finish. Never holds
    /// `.userRequested` requests — those interrupt immediately instead of queueing. Capped at
    /// `queueCap`, dropping the oldest entry first.
    private var pendingAutomaticQueue: [SpeechRequest] = []

    init(router: TTSRouter, options: @escaping () -> TTSOptions, overlay: ActivityOverlayModel) {
        self.router = router
        self.options = options
        self.overlay = overlay
        router.setPlaybackEventHandler { [weak self] event, backend in
            self?.handle(event, backend: backend)
        }
    }

    func speak(_ request: SpeechRequest) async throws {
        switch request.mode {
        case .userRequested:
            pendingAutomaticQueue.removeAll()
            router.stop()
            try await start(request)
        case .automatic:
            guard !isSpeaking else {
                enqueue(request)
                return
            }
            try await start(request)
        }
    }

    func stop() {
        pendingAutomaticQueue.removeAll()
        router.stop()
        if let currentSessionID {
            overlay.cancel(sessionID: currentSessionID)
        }
        if let overlaySessionID = overlay.state.sessionID, overlaySessionID != currentSessionID {
            overlay.cancel(sessionID: overlaySessionID)
        }
        currentSessionID = nil
        pendingAutomaticSessions.removeAll()
        isSpeaking = false
    }

    /// No-ops for a stale (already-replaced) session ID; otherwise stops the
    /// router, hides only the matching overlay session, and clears any queued
    /// automatic backlog.
    func stop(sessionID: UUID) {
        guard router.stop(sessionID: sessionID) else { return }
        pendingAutomaticQueue.removeAll()
        overlay.cancel(sessionID: sessionID)
        if currentSessionID == sessionID {
            currentSessionID = nil
        }
        pendingAutomaticSessions.remove(sessionID)
        isSpeaking = false
    }

    func replayLast() async throws {
        guard let lastRequest else { return }

        pendingAutomaticQueue.removeAll()
        router.stop()
        let sessionID = UUID()
        currentSessionID = sessionID
        isSpeaking = true
        overlay.begin(sessionID: sessionID)
        overlay.prepareSpeaking(sessionID: sessionID)

        try await router.speak(text: lastRequest.text, options: options(), sessionID: sessionID)
    }

    /// Appends `request` to the automatic backlog, dropping the oldest entry first if that would
    /// exceed `queueCap`.
    private func enqueue(_ request: SpeechRequest) {
        pendingAutomaticQueue.append(request)
        if pendingAutomaticQueue.count > Self.queueCap {
            pendingAutomaticQueue.removeFirst(pendingAutomaticQueue.count - Self.queueCap)
        }
    }

    /// Hands `request` to the router right now. Only ever called when nothing else is in flight
    /// (either because nothing was playing, or because the caller just force-stopped whatever
    /// was).
    private func start(_ request: SpeechRequest) async throws {
        let sessionID = UUID()
        currentSessionID = sessionID
        isSpeaking = true

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

    /// Called for every terminal playback event belonging to the session currently in flight.
    /// Clears the busy flag and, if anything is queued, starts the next automatic request.
    private func finishInFlightSession(_ sessionID: UUID) {
        guard sessionID == currentSessionID else { return }
        isSpeaking = false
        guard !pendingAutomaticQueue.isEmpty else { return }
        let next = pendingAutomaticQueue.removeFirst()
        Task { [weak self] in
            try? await self?.speak(next)
        }
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
            if pendingAutomaticSessions.remove(sessionID) == nil {
                overlay.complete(sessionID: sessionID)
            }
            finishInFlightSession(sessionID)
        case let .cancelled(sessionID):
            if pendingAutomaticSessions.remove(sessionID) == nil {
                overlay.cancel(sessionID: sessionID)
            }
            finishInFlightSession(sessionID)
        case let .failed(sessionID):
            if pendingAutomaticSessions.remove(sessionID) != nil {
                overlay.begin(sessionID: sessionID)
            }
            overlay.fail(sessionID: sessionID, category: .speechPlayback, message: "Speech playback failed.")
            finishInFlightSession(sessionID)
        }
    }
}
