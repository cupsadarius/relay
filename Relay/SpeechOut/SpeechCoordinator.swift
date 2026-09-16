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

    /// How long a single in-flight session may sit "speaking" with no terminal playback event
    /// before the queue gives up on it and treats it as abandoned. This is deliberately generous
    /// — far longer than any legitimate utterance — because it exists only as a defense-in-depth
    /// self-heal, not a normal control-flow path.
    ///
    /// Why this exists: `isSpeaking` is otherwise only ever cleared by a terminal
    /// `.finished`/`.cancelled`/`.failed` event reaching `handle(_:)`. Tracing every real
    /// playback path (`AppleTTSBackend` via `AVSpeechSynthesizerDelegate`'s didFinish/didCancel,
    /// `SynthesizedAudioPlayer` via `AVAudioPlayerDelegate`'s didFinishPlaying,
    /// `StreamingAudioPlayer` via `AVAudioPlayerNode` buffer-completion callbacks, and
    /// `TTSRouter.speak(...)`'s synchronous `.failed` emission on a start failure) shows each one
    /// *should* always deliver exactly one terminal event per session. But that guarantee rests on
    /// AVFoundation delegate/completion contracts under conditions this codebase can't fully
    /// exercise from tests (a mid-playback decode error, an audio route change interrupting
    /// `AVAudioEngine`, or a rare OS bug) — if any of those ever silently drops a terminal event,
    /// `isSpeaking` would otherwise stay `true` forever and every future `.automatic` response
    /// would queue silently, permanently killing auto-read until a manual Stop. This bound makes
    /// that failure mode self-heal instead.
    private static let staleInFlightTimeout: TimeInterval = 300

    private let router: TTSRouter
    private let options: () -> TTSOptions
    private let overlay: ActivityOverlayModel
    private let now: () -> Date
    /// How long the independent playback watchdog (`startWatchdog(for:)`) waits, from the moment
    /// a session is handed to the router, before giving up on it if no terminal event has
    /// arrived. Unlike `staleInFlightTimeout` this is a real wall-clock duration (driven by
    /// `Task.sleep`, not the injectable `now()` clock), so tests can shorten it directly rather
    /// than by faking time.
    private let watchdogTimeout: TimeInterval
    private var lastRequest: SpeechRequest?
    private var currentSessionID: UUID?
    /// When the currently in-flight session was handed to the router. `nil` whenever nothing is
    /// in flight. Used only by the `staleInFlightTimeout` self-heal check.
    private var inFlightStartedAt: Date?
    /// The watchdog `Task` for the currently in-flight session, if any. Cancelled the moment a
    /// terminal event (or an explicit `stop`) retires that session, so it never fires after a
    /// legitimate finish; replaced (not merely cancelled) whenever a new session starts.
    private var watchdogTask: Task<Void, Never>?
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
        now: @escaping () -> Date = Date.init,
        watchdogTimeout: TimeInterval = SpeechCoordinator.staleInFlightTimeout
    ) {
        self.router = router
        self.options = options
        self.overlay = overlay
        self.now = now
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
                if isInFlightSessionStale() {
                    // Self-heal: the in-flight session's backend apparently dropped its terminal
                    // event. Give up on tracking it any further and take over immediately, rather
                    // than queueing behind a session that will never finish.
                    isSpeaking = false
                } else {
                    enqueue(request)
                    return
                }
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
        inFlightStartedAt = nil
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
            cancelWatchdog()
            currentSessionID = nil
            inFlightStartedAt = nil
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
        inFlightStartedAt = now()
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

    /// Whether the currently in-flight session has been "speaking" with no terminal event for at
    /// least `staleInFlightTimeout`. See that constant's doc comment for why this exists.
    ///
    /// This is now a backstop behind the independent `startWatchdog(for:)` timer, which
    /// self-heals a wedged session on its own without waiting for a new request to arrive. This
    /// check is kept anyway because it is driven by the injectable `now()` clock rather than real
    /// wall-clock time, so it stays reachable deterministically in a single synchronous test step
    /// (jump the fake clock, then call `speak(_:)`) in a way the real-time watchdog cannot be.
    private func isInFlightSessionStale() -> Bool {
        guard let inFlightStartedAt else { return false }
        return now().timeIntervalSince(inFlightStartedAt) >= Self.staleInFlightTimeout
    }

    /// Starts (replacing any previous) watchdog timer for `sessionID`. Runs independently of the
    /// router's `.started` event so a streaming backend's start timing can never gate recovery:
    /// the clock starts the moment the session is accepted, not when playback audibly begins. If
    /// `sessionID` is still the in-flight session once `watchdogTimeout` elapses with no terminal
    /// event, the session is treated as abandoned - see `handleWatchdogExpiry(sessionID:)`.
    private func startWatchdog(for sessionID: UUID) {
        watchdogTask?.cancel()
        let timeout = max(watchdogTimeout, 0)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleWatchdogExpiry(sessionID: sessionID)
        }
    }

    /// Cancels the in-flight session's watchdog timer, if any. Called whenever that session is
    /// retired through any path (a terminal event, an explicit `stop`, or a new session starting)
    /// so the watchdog never fires after a legitimate finish.
    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Fires when a session's watchdog timer elapses with no terminal event observed. Guards that
    /// `sessionID` is still the in-flight session - a terminal may have raced in and already
    /// retired it (which also cancels this timer, but cancellation and expiry can still land in
    /// the same MainActor turn) - before treating it as abandoned: stops the backend, reports a
    /// privacy-safe failure (mirroring the `.failed` handling in `handle(_:backend:)`), and drains
    /// the queue via `finishInFlightSession(_:)`.
    private func handleWatchdogExpiry(sessionID: UUID) {
        guard sessionID == currentSessionID else { return }
        router.stop()
        if pendingAutomaticSessions.remove(sessionID) != nil {
            overlay.begin(sessionID: sessionID)
        }
        overlay.fail(sessionID: sessionID, category: .speechPlayback, message: "Speech playback failed.")
        finishInFlightSession(sessionID)
    }

    /// Hands `request` to the router right now. Only ever called when nothing else is in flight
    /// (either because nothing was playing, or because the caller just force-stopped whatever
    /// was).
    private func start(_ request: SpeechRequest) async throws {
        let sessionID = UUID()
        currentSessionID = sessionID
        inFlightStartedAt = now()
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
        inFlightStartedAt = nil
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
