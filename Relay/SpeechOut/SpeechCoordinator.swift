import Foundation

@MainActor
protocol SpeechCoordinating: AnyObject {
    func speak(_ request: SpeechRequest) async throws
    func previewVoice(text: String, backendID: BackendID, options: TTSOptions) async throws
    func stop()
    func stop(sessionID: UUID)
    func replayLast() async throws
    /// Replays the last request, announcing its speak step into `tracer`.
    func replayLast(tracer: PipelineTracer?) async throws
}

extension SpeechCoordinating {
    func replayLast(tracer: PipelineTracer?) async throws { try await replayLast() }
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

    private struct ActiveSession {
        let id: UUID
        /// Automatic sessions show in the overlay only once playback starts or fails, so a queued
        /// request never hides the capsule of what is still speaking.
        var shownInOverlay: Bool
        var watchdog: Task<Void, Never>
        /// Announces this session's speak step.
        let tracer: PipelineTracer?
        var backendName: String?
    }

    private enum InFlight {
        case idle
        case active(ActiveSession)
    }

    private let router: TTSRouter
    private let options: () -> TTSOptions
    private let overlay: ActivityOverlayModel
    private let watchdogTimeout: TimeInterval
    private var lastRequest: SpeechRequest?
    /// While `.active`, a new `.automatic` request is enqueued rather than overlapping it. Events
    /// for any other session are ignored, including the `.cancelled` the player emits reentrantly
    /// from `router.stop()` after a session has been retired.
    private var inFlight: InFlight = .idle
    /// FIFO backlog of `.automatic` requests waiting for the current one to finish. Never holds
    /// `.userRequested` requests — those interrupt immediately instead of queueing. Capped at
    /// `queueCap`, dropping the oldest entry first.
    private var pendingAutomaticQueue: [SpeechRequest] = []
    /// While `true`, `.automatic` requests wait in the queue, so they never play over a dictation.
    private var automaticHeld = false

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
            interrupt()
            try await start(request)
        case .automatic:
            if automaticHeld {
                request.tracer?.start(.speak, "Waiting for dictation to end")
                enqueue(request)
                return
            }
            if case .active = inFlight {
                request.tracer?.start(.speak, "Queued behind other speech")
                enqueue(request)
                return
            }
            try await start(request)
        }
    }

    func holdAutomaticSpeech(_ held: Bool) {
        automaticHeld = held
        if !held, case .idle = inFlight { drainQueueIfNeeded() }
    }

    func stop() {
        dropQueue("Stopped")
        let retired = retire()
        retired?.tracer?.stop(.speak, "Stopped")
        router.stop()
        if let retired {
            overlay.cancel(sessionID: retired.id)
        }
        if let overlaySessionID = overlay.state.sessionID {
            overlay.cancel(sessionID: overlaySessionID)
        }
    }

    func previewVoice(text: String, backendID: BackendID, options: TTSOptions) async throws {
        interrupt()
        let sessionID = begin(showInOverlay: true, tracer: nil)
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
        dropQueue("Stopped")
        if case let .active(session) = inFlight, session.id == sessionID {
            retire()
            session.tracer?.stop(.speak, "Stopped")
        }
        router.stop(sessionID: sessionID)
        overlay.cancel(sessionID: sessionID)
    }

    func replayLast() async throws {
        try await replayLast(tracer: nil)
    }

    func replayLast(tracer: PipelineTracer?) async throws {
        guard let lastRequest else {
            tracer?.stop(.speak, "Nothing to replay")
            return
        }
        interrupt()
        let sessionID = begin(showInOverlay: true, tracer: tracer)
        try await announcing(tracer) {
            try await router.speak(text: lastRequest.text, options: options(), sessionID: sessionID)
        }
    }

    /// Hands `request` to the router right now. Only ever called when nothing else is in flight
    /// (either because nothing was playing, or because the caller just interrupted whatever was).
    private func start(_ request: SpeechRequest) async throws {
        let sessionID = begin(showInOverlay: request.mode == .userRequested, tracer: request.tracer)
        try await announcing(request.tracer) {
            try await router.speak(text: request.text, options: options(), sessionID: sessionID)
        }
        lastRequest = request
    }

    /// Announces the speak step's start, and its end when the router cannot start playback.
    private func announcing(_ tracer: PipelineTracer?, _ body: () async throws -> Void) async throws {
        tracer?.start(.speak, "Preparing speech")
        do {
            try await body()
        } catch is CancellationError {
            tracer?.stop(.speak, "Stopped")
            throw CancellationError()
        } catch {
            tracer?.fail(.speak, "Could not start speech")
            throw error
        }
    }

    /// Clears the automatic backlog and tells each dropped request's run why.
    private func dropQueue(_ reason: String) {
        for request in pendingAutomaticQueue { request.tracer?.stop(.speak, reason) }
        pendingAutomaticQueue.removeAll()
    }

    /// Clears the backlog and stops whatever is in flight; the caller's `begin` replaces the overlay.
    private func interrupt() {
        dropQueue("Interrupted")
        retire()?.tracer?.stop(.speak, "Interrupted")
        router.stop()
    }

    /// The first watchdog deadline starts at acceptance, so a backend that never begins playback
    /// is still recovered.
    private func begin(showInOverlay: Bool, tracer: PipelineTracer?) -> UUID {
        let sessionID = UUID()
        inFlight = .active(
            ActiveSession(
                id: sessionID, shownInOverlay: showInOverlay, watchdog: makeWatchdog(for: sessionID), tracer: tracer
            )
        )
        if showInOverlay {
            overlay.begin(sessionID: sessionID)
            overlay.prepareSpeaking(sessionID: sessionID)
        }
        return sessionID
    }

    /// Returns to `.idle` and cancels the watchdog, so a retired session never fires it and a
    /// second terminal event for it is ignored instead of dequeuing twice.
    @discardableResult
    private func retire() -> ActiveSession? {
        guard case let .active(session) = inFlight else { return nil }
        session.watchdog.cancel()
        inFlight = .idle
        return session
    }

    /// Appends `request` to the automatic backlog, dropping the oldest entry first if that would
    /// exceed `queueCap`.
    private func enqueue(_ request: SpeechRequest) {
        pendingAutomaticQueue.append(request)
        if pendingAutomaticQueue.count > Self.queueCap {
            let overflow = pendingAutomaticQueue.count - Self.queueCap
            for dropped in pendingAutomaticQueue.prefix(overflow) { dropped.tracer?.stop(.speak, "Dropped: speech queue full") }
            pendingAutomaticQueue.removeFirst(overflow)
        }
    }

    private func makeWatchdog(for sessionID: UUID) -> Task<Void, Never> {
        let timeout = max(watchdogTimeout, 0)
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleWatchdogExpiry(sessionID: sessionID)
        }
    }

    private func rearmWatchdog(_ session: inout ActiveSession) {
        session.watchdog.cancel()
        session.watchdog = makeWatchdog(for: session.id)
    }

    private func handleWatchdogExpiry(sessionID: UUID) {
        guard case let .active(session) = inFlight, session.id == sessionID else { return }
        retire()
        session.tracer?.fail(.speak, "Playback timed out")
        router.stop()
        if !session.shownInOverlay {
            overlay.begin(sessionID: sessionID)
        }
        overlay.fail(sessionID: sessionID, category: .speechPlayback, message: "Speech playback failed.")
        drainQueueIfNeeded()
    }

    /// Starts the next queued automatic request, if any.
    private func drainQueueIfNeeded() {
        guard !automaticHeld, !pendingAutomaticQueue.isEmpty else { return }
        let next = pendingAutomaticQueue.removeFirst()
        Task { [weak self] in
            try? await self?.speak(next)
        }
    }

    private func handle(_ event: TTSPlaybackEvent, backend: (any TextToSpeechBackend)?) {
        guard case var .active(session) = inFlight, session.id == event.sessionID else { return }
        let sessionID = session.id
        switch event {
        case .started:
            rearmWatchdog(&session)
            if !session.shownInOverlay {
                session.shownInOverlay = true
                overlay.begin(sessionID: sessionID)
            }
            if let backend {
                session.backendName = backend.id.displayName
                session.tracer?.update(.speak, "Speaking with \(backend.id.displayName)")
            }
            inFlight = .active(session)
            overlay.speak(sessionID: sessionID)
            if let backend {
                overlay.setBackendName(backend.id.displayName, sessionID: sessionID)
            }
        case let .level(_, level):
            rearmWatchdog(&session)
            inFlight = .active(session)
            overlay.updateSpeakingLevel(level, sessionID: sessionID)
        case .finished:
            session.tracer?.finish(.speak, session.backendName ?? "Done")
            if session.shownInOverlay {
                overlay.complete(sessionID: sessionID)
            }
            retire()
            drainQueueIfNeeded()
        case .cancelled:
            session.tracer?.stop(.speak, "Stopped")
            if session.shownInOverlay {
                overlay.cancel(sessionID: sessionID)
            }
            retire()
            drainQueueIfNeeded()
        case .failed:
            session.tracer?.fail(.speak, "Playback failed")
            if !session.shownInOverlay {
                overlay.begin(sessionID: sessionID)
            }
            overlay.fail(sessionID: sessionID, category: .speechPlayback, message: "Speech playback failed.")
            retire()
            drainQueueIfNeeded()
        }
    }
}
