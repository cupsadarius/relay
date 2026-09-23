import Foundation

/// Chooses a TTS backend and drives one shared `StreamingAudioPlayer` with the `TTSAudioSource` it
/// produces. Backends are pure audio producers; the router owns backend selection, fallback, and
/// the single playback lifecycle.
///
/// Fallback is allowed only BEFORE audible playback starts (backend unavailable, `makeAudioSource`
/// failure, or a pre-`.started` player failure). Once the player emits `.started` the backend is
/// committed for that session: a later failure ends the session as `.failed` and never restarts the
/// response in another voice.
@MainActor
final class TTSRouter {
    private let backends: [String: any TextToSpeechBackend]
    private let backendOrder: () -> [String]
    private let player: any StreamingAudioPlaying

    /// The backend for the session the player is currently driving. Assigned BEFORE
    /// `startPlayback` because the player emits `.started` (committing the backend) while
    /// `startPlayback` is still suspended - `forward` needs the candidate set at that point.
    private struct CandidatePlayback {
        let backend: any TextToSpeechBackend
        let sessionID: UUID
    }

    private var candidate: CandidatePlayback?
    /// The session `speak` is currently routing, set before any backend is consulted. A backend
    /// can spend seconds inside `makeAudioSource` (Kokoro/PocketTTS model loads) before
    /// `candidate` exists, so `stop(sessionID:)` also matches this, or a Stop pressed during
    /// preparation would be ignored.
    private var routingSessionID: UUID?
    private var eventHandler: (@MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void)?
    private var routingGeneration = 0

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
    /// `.failed` carries a `nil` backend (it is emitted before, or independently of, a
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
        routingGeneration &+= 1
        let generation = routingGeneration
        routingSessionID = sessionID
        defer {
            // A newer `speak` may already own `routingSessionID`; only clear our own.
            if routingSessionID == sessionID { routingSessionID = nil }
        }
        var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

        let candidateIDs = preferredBackendID.map { [$0] } ?? backendOrder()
        for id in candidateIDs {
            guard let backend = backends[id] else { continue }
            let availability = await backend.availability()
            guard generation == routingGeneration else { throw CancellationError() }
            guard case .available = availability else { continue }

            let source: any TTSAudioSource
            do {
                source = try await backend.makeAudioSource(text: text, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                guard generation == routingGeneration else { throw CancellationError() }
                lastError = error
                continue
            } catch {
                guard generation == routingGeneration else { throw CancellationError() }
                eventHandler?(.failed(sessionID: sessionID), nil)
                throw error
            }

            guard generation == routingGeneration else {
                await source.cancel()
                throw CancellationError()
            }

            candidate = CandidatePlayback(backend: backend, sessionID: sessionID)

            do {
                try await player.startPlayback(source, sessionID: sessionID)
                guard generation == routingGeneration else {
                    await source.cancel()
                    clearCandidate(sessionID: sessionID)
                    throw CancellationError()
                }
                return
            } catch is CancellationError {
                await source.cancel()
                clearCandidate(sessionID: sessionID)
                throw CancellationError()
            } catch {
                // `startPlayback` only throws before `.started`; after `.started` the player reports
                // terminal failure asynchronously. So a thrown error here is always pre-commit and
                // safe to treat as fallback-worthy.
                await source.cancel()
                clearCandidate(sessionID: sessionID)
                guard generation == routingGeneration else { throw CancellationError() }
                lastError = .inferenceFailed("TTS playback failed")
                continue
            }
        }

        guard generation == routingGeneration else { throw CancellationError() }
        eventHandler?(.failed(sessionID: sessionID), nil)
        throw lastError
    }

    func stop() {
        routingGeneration &+= 1
        routingSessionID = nil
        player.stop()
    }

    /// No-ops unless `sessionID` matches the session currently being routed (still preparing its
    /// source) or played, so a stale Interactive Stop cannot cut off replacement speech. Returns
    /// whether the ID matched and a stop was issued. A stop during preparation bumps
    /// `routingGeneration`, so `speak`'s post-`makeAudioSource` guard cancels the new source and
    /// throws `CancellationError` instead of starting playback.
    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard routingSessionID == sessionID || candidate?.sessionID == sessionID else { return false }
        stop()
        return true
    }

    private func clearCandidate(sessionID: UUID) {
        if candidate?.sessionID == sessionID {
            candidate = nil
        }
    }

    private func forward(_ event: TTSPlaybackEvent) {
        guard let candidate, event.sessionID == candidate.sessionID else { return }
        switch event {
        case .started:
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
