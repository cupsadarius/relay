import Foundation

@MainActor
final class TTSRouter {
    private let backends: [String: any TextToSpeechBackend]
    private let backendOrder: () -> [String]
    private var activeBackend: (any TextToSpeechBackend)?
    private var activeSessionID: UUID?
    /// The backend/session currently inside a `speak(...)` call, so events
    /// emitted synchronously (or after a suspension) before that call
    /// returns are still forwarded even though `activeBackend`/
    /// `activeSessionID` are only assigned once it succeeds.
    private var routingBackend: (any TextToSpeechBackend)?
    private var routingSessionID: UUID?
    private var eventHandler: (@MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void)?

    init(
        backends: [String: any TextToSpeechBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
        for backend in backends.values {
            backend.setPlaybackEventHandler { [weak self, weak backend] event in
                guard let backend else { return }
                self?.forward(event, from: backend)
            }
        }
    }

    /// Installs the single downstream listener for playback lifecycle
    /// events. Only events raised by the currently routed or active
    /// backend, for the matching session, are forwarded — except router-
    /// emitted `.failed` events, which bypass that filter by design so a
    /// failure is never swallowed just because routing/activity state has
    /// already moved on. Because it bypasses the filter, a router-emitted
    /// `.failed` always carries a `nil` backend rather than whichever
    /// backend most recently failed.
    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void) {
        eventHandler = handler
    }

    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
        var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

        for id in backendOrder() {
            guard let backend = backends[id] else { continue }
            guard case .available = await backend.availability() else { continue }

            do {
                if let activeBackend, activeBackend !== backend {
                    activeBackend.stop()
                    self.activeBackend = nil
                    activeSessionID = nil
                }
                routingBackend = backend
                routingSessionID = sessionID
                defer {
                    routingBackend = nil
                    routingSessionID = nil
                }
                try await backend.speak(text: text, options: options, sessionID: sessionID)
                activeBackend = backend
                activeSessionID = sessionID
                return
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
            } catch {
                eventHandler?(.failed(sessionID: sessionID), nil)
                throw error
            }
        }

        eventHandler?(.failed(sessionID: sessionID), nil)
        throw lastError
    }

    func stop() {
        // Prefer the in-flight routing pair: during a STREAMING backend's
        // `speak(...)`, that call doesn't return until playback finishes, so
        // `activeBackend`/`activeSessionID` aren't assigned yet even though
        // the backend is the one actually playing. `routingBackend`/
        // `routingSessionID` are left untouched here — the in-flight
        // `speak(...)`'s own `defer` clears them once it returns.
        (routingBackend ?? activeBackend)?.stop()
        activeBackend = nil
        activeSessionID = nil
    }

    /// No-ops unless `sessionID` matches the session currently being routed
    /// or already active, so a stale Interactive Stop cannot cut off
    /// replacement speech. Returns whether the ID matched and a stop was
    /// actually issued.
    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard routingSessionID == sessionID || activeSessionID == sessionID else { return false }
        stop()
        return true
    }

    func pause() {
        activeBackend?.pause()
    }

    func resume() {
        activeBackend?.resume()
    }

    private func forward(_ event: TTSPlaybackEvent, from backend: any TextToSpeechBackend) {
        if let routingBackend, routingBackend === backend,
           let routingSessionID, event.sessionID == routingSessionID {
            eventHandler?(event, backend)
            return
        }
        guard let activeBackend, activeBackend === backend,
              let activeSessionID, event.sessionID == activeSessionID else { return }
        eventHandler?(event, backend)
    }
}
