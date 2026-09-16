import Foundation

@MainActor
final class TTSRouter {
    private let backends: [String: any TextToSpeechBackend]
    private let backendOrder: () -> [String]
    /// The single playback currently owned by the router. Assigned BEFORE
    /// `speak(...)` is called on the backend (not after it returns), because
    /// backends emit `.scheduled`/`.started` synchronously (or after a
    /// suspension) while `speak(...)` is still executing - `forward` needs
    /// `active` set at that point or those events are silently dropped.
    private struct ActivePlayback {
        let backend: any TextToSpeechBackend
        let sessionID: UUID
    }
    private var active: ActivePlayback?
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
    /// events. Only events raised by the currently active backend, for the
    /// matching session, are forwarded - except router-emitted `.failed`
    /// events, which bypass that filter by design so a failure is never
    /// swallowed just because the active playback state has already moved
    /// on. Because it bypasses the filter, a router-emitted `.failed`
    /// always carries a `nil` backend rather than whichever backend most
    /// recently failed.
    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void) {
        eventHandler = handler
    }

    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
        var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

        for id in backendOrder() {
            guard let backend = backends[id] else { continue }
            guard case .available = await backend.availability() else { continue }

            if let active, active.backend !== backend {
                active.backend.stop()
                self.active = nil
            }
            // Assigned before `speak(...)` is invoked: `.scheduled`/`.started`
            // are emitted synchronously inside that call, so `active` must
            // already be set for `forward` to pass them through.
            active = ActivePlayback(backend: backend, sessionID: sessionID)

            do {
                try await backend.speak(text: text, options: options, sessionID: sessionID)
                return
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                active = nil
                lastError = error
            } catch {
                active = nil
                eventHandler?(.failed(sessionID: sessionID), nil)
                throw error
            }
        }

        eventHandler?(.failed(sessionID: sessionID), nil)
        throw lastError
    }

    func stop() {
        active?.backend.stop()
        active = nil
    }

    /// No-ops unless `sessionID` matches the session currently active, so a
    /// stale Interactive Stop cannot cut off replacement speech. Returns
    /// whether the ID matched and a stop was actually issued.
    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard active?.sessionID == sessionID else { return false }
        stop()
        return true
    }

    func pause() {
        active?.backend.pause()
    }

    func resume() {
        active?.backend.resume()
    }

    private func forward(_ event: TTSPlaybackEvent, from backend: any TextToSpeechBackend) {
        guard let active, active.backend === backend, event.sessionID == active.sessionID else { return }
        eventHandler?(event, backend)
        if Self.isTerminal(event) {
            self.active = nil
        }
    }

    private static func isTerminal(_ event: TTSPlaybackEvent) -> Bool {
        switch event {
        case .finished, .cancelled, .failed:
            true
        case .scheduled, .started, .level:
            false
        }
    }
}
