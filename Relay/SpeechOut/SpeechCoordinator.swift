import Foundation

@MainActor
protocol SpeechCoordinating: AnyObject {
    func speak(_ request: SpeechRequest) async throws
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws
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

/// `SpeechCoordinator` is `@MainActor`, so it is already `Sendable`; cross-isolation callers
/// such as `AgentAutoReadCoordinator` can hold it as `any SpeechSubmitting & Sendable`.
extension SpeechCoordinator: SpeechSubmitting {}

@MainActor
final class SpeechCoordinator: SpeechCoordinating {
    /// Most-recent automatic requests are kept when the queue overflows; older ones are dropped
    /// first so a long silent backlog can never build up behind whatever is currently playing.
    private static let queueCap = 8

    /// Longest gap with no playback progress before the watchdog retires a session.
    static let defaultWatchdogTimeout: TimeInterval = 300

    private let router: TTSRouter
    private let options: () -> TTSOptions
    private let overlay: ActivityOverlayModel
    private let watchdogTimeout: TimeInterval
    private var lastRequest: SpeechRequest?
    private var currentSessionID: UUID?
    /// The watchdog `Task` for the currently in-flight session, if any. Cancelled the moment a
    /// terminal event (or an explicit `stop`) retires that session, so it never fires after a
    /// legitimate finish; replaced (not merely cancelled) whenever a new session starts.
    private var watchdogTask: Task<Void, Never>?
    /// Set to a session ID only for the duration of `handleWatchdogExpiry(sessionID:)`'s call to
    /// `router.stop()`, and `nil` otherwise. The shared `StreamingAudioPlayer` emits its terminal
    /// `.cancelled` SYNCHRONOUSLY and reentrantly from inside `stop()`, before it returns;
    /// `handle(_:backend:)` ignores any event for this session while it's set, so that reentrant
    /// terminal can't race the watchdog's own `.failed` overlay update or double-drain the queue.
    private var watchdogRetiringSessionID: UUID?
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

    init(
        router: TTSRouter,
        options: @escaping () -> TTSOptions,
        overlay: ActivityOverlayModel,
        watchdogTimeout: TimeInterval = SpeechCoordinator.defaultWatchdogTimeout
    ) {
        self.router = router
        self.options = options
        self.overlay = overlay
        self.watchdogTimeout = watchdogTimeout
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
            if isSpeaking {
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
        cancelWatchdog()
        currentSessionID = nil
        pendingAutomaticSessions.removeAll()
        isSpeaking = false
    }

    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {
        pendingAutomaticQueue.removeAll()
        router.stop()
        cancelWatchdog()
        let sessionID = UUID()
        currentSessionID = sessionID
        isSpeaking = true
        startWatchdog(for: sessionID)
        overlay.begin(sessionID: sessionID)
        overlay.prepareSpeaking(sessionID: sessionID)
        try await router.speak(
            text: text,
            options: options,
            sessionID: sessionID,
            preferredBackendID: backendID
        )
    }

    /// No-ops for a stale (already-replaced) session ID; otherwise stops the
    /// router, hides only the matching overlay session, and clears any queued
    /// automatic backlog.
    func stop(sessionID: UUID) {
        guard router.owns(sessionID) else { return }
        // Clear first: the player emits `.cancelled` synchronously, and that drains the queue.
        pendingAutomaticQueue.removeAll()
        router.stop(sessionID: sessionID)
        overlay.cancel(sessionID: sessionID)
        if currentSessionID == sessionID {
            cancelWatchdog()
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
        startWatchdog(for: sessionID)
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

    /// Starts (replacing any previous) watchdog timer for `sessionID`. The first deadline starts
    /// when the session is accepted, so a backend that never begins playback is still recovered.
    /// Once playback is active, `recordPlaybackProgress(sessionID:)` rearms this timer on every
    /// progress event. If the current session produces neither progress nor a terminal event for
    /// `watchdogTimeout`, it is treated as abandoned - see `handleWatchdogExpiry(sessionID:)`.
    private func startWatchdog(for sessionID: UUID) {
        watchdogTask?.cancel()
        let timeout = max(watchdogTimeout, 0)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleWatchdogExpiry(sessionID: sessionID)
        }
    }

    /// Cancels the in-flight session's watchdog timer, if any. Called whenever that session is
    /// retired through any path (a terminal event, an explicit `stop`, or a new session starting)
    /// so the watchdog never fires after a legitimate finish.
    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Rearms the watchdog only for the current session. A stale player's delayed `.started` or
    /// `.level` event must never extend the replacement session's deadline.
    private func recordPlaybackProgress(sessionID: UUID) {
        guard sessionID == currentSessionID else { return }
        startWatchdog(for: sessionID)
    }

    /// Fires when a session's watchdog timer elapses with no terminal event observed. Guards that
    /// `sessionID` is still the in-flight session - a terminal may have raced in and already
    /// retired it (which also cancels this timer, but cancellation and expiry can still land in
    /// the same MainActor turn) - before treating it as abandoned.
    ///
    /// Retires this session's own tracking BEFORE calling `router.stop()`, rather than going
    /// through `finishInFlightSession(_:)` afterwards: the shared `StreamingAudioPlayer` emits
    /// `.cancelled` reentrantly from inside `stop()`, and `watchdogRetiringSessionID` makes
    /// `handle(_:backend:)` ignore it for that call's duration. Without both of these, that
    /// reentrant `.cancelled` would race ahead of this method's own `.failed` report — clearing
    /// the overlay's `activeSessionID` (so the subsequent `overlay.fail(...)` below silently
    /// no-ops) and dequeuing the next request itself (so the drain at the end here would double
    /// it). Retiring first and suppressing the reentrant event makes both of those impossible.
    private func handleWatchdogExpiry(sessionID: UUID) {
        guard sessionID == currentSessionID else { return }
        cancelWatchdog()
        currentSessionID = nil
        isSpeaking = false

        watchdogRetiringSessionID = sessionID
        router.stop()
        watchdogRetiringSessionID = nil

        if pendingAutomaticSessions.remove(sessionID) != nil {
            overlay.begin(sessionID: sessionID)
        }
        overlay.fail(sessionID: sessionID, category: .speechPlayback, message: "Speech playback failed.")
        drainQueueIfNeeded()
    }

    /// Hands `request` to the router right now. Only ever called when nothing else is in flight
    /// (either because nothing was playing, or because the caller just force-stopped whatever
    /// was).
    private func start(_ request: SpeechRequest) async throws {
        let sessionID = UUID()
        currentSessionID = sessionID
        isSpeaking = true
        startWatchdog(for: sessionID)

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
    ///
    /// Clears `currentSessionID` (not just `isSpeaking`) so a second terminal event for the same
    /// session — a duplicate `.finished`, or `.cancelled` followed by a late `.finished` — finds
    /// `sessionID == currentSessionID` false and is a no-op, instead of dequeuing and starting a
    /// second automatic request on top of the one the first terminal event already started.
    private func finishInFlightSession(_ sessionID: UUID) {
        guard sessionID == currentSessionID else { return }
        cancelWatchdog()
        currentSessionID = nil
        isSpeaking = false
        drainQueueIfNeeded()
    }

    /// Starts the next queued automatic request, if any. Shared by `finishInFlightSession(_:)`
    /// (the normal terminal-event path) and `handleWatchdogExpiry(sessionID:)` (which retires its
    /// session itself and so calls this directly, rather than through `finishInFlightSession(_:)`).
    private func drainQueueIfNeeded() {
        guard !pendingAutomaticQueue.isEmpty else { return }
        let next = pendingAutomaticQueue.removeFirst()
        Task { [weak self] in
            try? await self?.speak(next)
        }
    }

    private func handle(_ event: TTSPlaybackEvent, backend: (any TextToSpeechBackend)?) {
        // A watchdog-driven `router.stop()` is in progress for this exact session: ignore
        // whatever it synchronously, reentrantly emits. See `watchdogRetiringSessionID`'s doc
        // comment.
        guard event.sessionID != watchdogRetiringSessionID else { return }
        switch event {
        case let .started(sessionID):
            recordPlaybackProgress(sessionID: sessionID)
            if pendingAutomaticSessions.remove(sessionID) != nil {
                overlay.begin(sessionID: sessionID)
            }
            overlay.speak(sessionID: sessionID)
            if let backend {
                overlay.setBackendName(backend.displayName, sessionID: sessionID)
            }
        case let .level(sessionID, level):
            recordPlaybackProgress(sessionID: sessionID)
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
