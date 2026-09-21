import Foundation

/// Chooses a TTS backend and drives one shared `StreamingAudioPlayer` with the `TTSAudioSource` it
/// produces. Backends are pure audio producers; the router owns backend selection, fallback, and
/// the single playback lifecycle.
///
/// Fallback is allowed only BEFORE audible playback starts (backend unavailable, `makeAudioSource`
/// failure, or a pre-`.started` player failure). Once the player emits `.started` the backend is
/// committed for that session: a later failure ends the session as `.failed` and never restarts the
/// response in another voice. `.scheduled` is emitted exactly once per Relay speech session, not
/// once per backend attempt.
@MainActor
final class TTSRouter {
    private let backends: [String: any TextToSpeechBackend]
    private let backendOrder: () -> [String]
    private let player: any StreamingAudioPlaying

    /// The backend/source pair for the session the player is currently driving. Assigned BEFORE
    /// `startPlayback` because the player emits `.started` (committing the backend) while
    /// `startPlayback` is still suspended - `forward` needs the candidate set at that point.
    private struct CandidatePlayback {
        let backend: any TextToSpeechBackend
        let source: any TTSAudioSource
        let sessionID: UUID
        var committed: Bool
    }

    private var candidate: CandidatePlayback?
    private var eventHandler: (@MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void)?

    init(
        backends: [String: any TextToSpeechBackend],
        backendOrder: @escaping () -> [String],
        player: any StreamingAudioPlaying
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
        self.player = player
        self.player.onEvent = { [weak self] event in
            self?.forward(event)
        }
    }

    /// Installs the single downstream listener for playback lifecycle events. Router-emitted
    /// `.scheduled`/`.failed` carry a `nil` backend (they are emitted before, or independently of, a
    /// committed backend); player-sourced events carry the committed backend.
    func setPlaybackEventHandler(
        _ handler: @escaping @MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void
    ) {
        eventHandler = handler
    }

    func speak(
        text: String,
        options: TTSOptions,
        sessionID: UUID,
        preferredBackendID: String? = nil
    ) async throws {
        // Emitted exactly once per Relay speech session, before any backend attempt, so fallback
        // attempts never duplicate it.
        eventHandler?(.scheduled(sessionID: sessionID), nil)

        var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

        let candidateIDs = preferredBackendID.map { [$0] } ?? backendOrder()
        for id in candidateIDs {
            guard let backend = backends[id] else { continue }
            guard case .available = await backend.availability() else { continue }

            let source: any TTSAudioSource
            do {
                source = try await backend.makeAudioSource(text: text, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
                continue
            } catch let error as SpeechBackendError {
                eventHandler?(.failed(sessionID: sessionID), nil)
                throw error
            } catch {
                eventHandler?(.failed(sessionID: sessionID), nil)
                throw error
            }

            candidate = CandidatePlayback(
                backend: backend,
                source: source,
                sessionID: sessionID,
                committed: false
            )

            do {
                try await player.startPlayback(source, sessionID: sessionID)
                return
            } catch is CancellationError {
                await source.cancel()
                candidate = nil
                throw CancellationError()
            } catch {
                // `startPlayback` only throws before `.started`; after `.started` the player reports
                // terminal failure asynchronously. So a thrown error here is always pre-commit and
                // safe to treat as fallback-worthy.
                await source.cancel()
                candidate = nil
                lastError = .inferenceFailed("TTS playback failed")
                continue
            }
        }

        eventHandler?(.failed(sessionID: sessionID), nil)
        throw lastError
    }

    func stop() {
        player.stop()
    }

    /// No-ops unless `sessionID` matches the session currently being played, so a stale Interactive
    /// Stop cannot cut off replacement speech. Returns whether the ID matched and a stop was issued.
    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard candidate?.sessionID == sessionID else { return false }
        stop()
        return true
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.resume()
    }

    private func forward(_ event: TTSPlaybackEvent) {
        guard var candidate, event.sessionID == candidate.sessionID else { return }
        switch event {
        case .scheduled:
            // The router already emitted `.scheduled` once for the session; the player's own
            // per-start `.scheduled` is suppressed so fallback cannot duplicate it.
            return
        case .started:
            candidate.committed = true
            self.candidate = candidate
            eventHandler?(event, candidate.backend)
        case .level:
            eventHandler?(event, candidate.backend)
        case .finished, .cancelled, .failed:
            let backend = candidate.backend
            self.candidate = nil
            eventHandler?(event, backend)
        }
    }
}
