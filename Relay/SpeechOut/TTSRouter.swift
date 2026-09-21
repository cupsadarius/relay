import Foundation

/// Transitional router for the unified TTS migration.
///
/// PocketTTS and Kokoro can produce `TTSAudioSource`s and therefore route through one shared
/// `StreamingAudioPlayer`. Apple intentionally remains on its native AVSpeechSynthesizer path
/// until the generated-audio quality gate is passed on a real Mac. Once that gate passes the
/// compatibility branch can be deleted and `makeAudioSource` folded into `TextToSpeechBackend`.
@MainActor
final class TTSRouter {
    private let backends: [String: any TextToSpeechBackend]
    private let backendOrder: () -> [String]
    private let sharedPlayer: (any TTSAudioPlaying)?

    private struct ActivePlayback {
        let backend: any TextToSpeechBackend
        let sessionID: UUID
        let usesSharedPlayer: Bool
        let source: (any TTSAudioSource)?
    }

    private var active: ActivePlayback?
    /// First backend/player attempt that actually schedules this speech session wins; later
    /// fallback attempts cannot duplicate the externally-visible `.scheduled` event.
    private var scheduledSessionID: UUID?
    private var eventHandler: (@MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void)?

    init(
        backends: [String: any TextToSpeechBackend],
        backendOrder: @escaping () -> [String],
        sharedPlayer: (any TTSAudioPlaying)? = nil
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
        self.sharedPlayer = sharedPlayer

        for backend in backends.values {
            backend.setPlaybackEventHandler { [weak self, weak backend] event in
                guard let backend else { return }
                self?.forwardLegacy(event, from: backend)
            }
        }
        sharedPlayer?.onEvent = { [weak self] event in
            self?.forwardShared(event)
        }
    }

    func setPlaybackEventHandler(
        _ handler: @escaping @MainActor (TTSPlaybackEvent, (any TextToSpeechBackend)?) -> Void
    ) {
        eventHandler = handler
    }

    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
        var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

        scheduledSessionID = nil

        for id in backendOrder() {
            guard let backend = backends[id] else { continue }
            guard case .available = await backend.availability() else { continue }

            stopActiveForReplacement()

            if
                let sharedPlayer,
                let producer = backend as? any TTSAudioSourceProducing
            {
                do {
                    let source = try await producer.makeAudioSource(text: text, options: options)
                    active = ActivePlayback(
                        backend: backend,
                        sessionID: sessionID,
                        usesSharedPlayer: true,
                        source: source
                    )
                    try await sharedPlayer.startPlayback(source, sessionID: sessionID)
                    return
                } catch is CancellationError {
                    active = nil
                    throw CancellationError()
                } catch let error as SpeechBackendError where error.isFallbackWorthy {
                    await cancelActiveSourceIfNeeded()
                    active = nil
                    lastError = error
                    continue
                } catch let error as SpeechBackendError {
                    await cancelActiveSourceIfNeeded()
                    active = nil
                    eventHandler?(.failed(sessionID: sessionID), nil)
                    throw error
                } catch {
                    // A source/player error before `.started` is fallback-worthy. After `.started`
                    // failures are delivered asynchronously by the shared player as `.failed`, so
                    // this catch is only the pre-commit path.
                    await cancelActiveSourceIfNeeded()
                    active = nil
                    lastError = .inferenceFailed("TTS playback failed")
                    continue
                }
            }

            // Compatibility exception: Apple still owns playback until its generated-PCM path
            // passes the owner-Mac quality gate.
            active = ActivePlayback(
                backend: backend,
                sessionID: sessionID,
                usesSharedPlayer: false,
                source: nil
            )
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
        guard let active else { return }
        if active.usesSharedPlayer {
            sharedPlayer?.stop()
            if let source = active.source {
                Task { await source.cancel() }
            }
        } else {
            active.backend.stop()
        }
        self.active = nil
    }

    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard active?.sessionID == sessionID else { return false }
        stop()
        return true
    }

    func pause() {
        guard let active else { return }
        if active.usesSharedPlayer {
            sharedPlayer?.pause()
        } else {
            active.backend.pause()
        }
    }

    func resume() {
        guard let active else { return }
        if active.usesSharedPlayer {
            sharedPlayer?.resume()
        } else {
            active.backend.resume()
        }
    }

    private func stopActiveForReplacement() {
        guard let active else { return }
        if active.usesSharedPlayer {
            sharedPlayer?.stop()
            if let source = active.source {
                Task { await source.cancel() }
            }
        } else {
            active.backend.stop()
        }
        self.active = nil
    }

    private func cancelActiveSourceIfNeeded() async {
        guard let active, active.usesSharedPlayer, let source = active.source else { return }
        await source.cancel()
    }

    private func forwardLegacy(_ event: TTSPlaybackEvent, from backend: any TextToSpeechBackend) {
        guard let active, !active.usesSharedPlayer, active.backend === backend, event.sessionID == active.sessionID else {
            return
        }
        if case .scheduled = event {
            forwardScheduledOnce(event, backend: backend)
            return
        }
        eventHandler?(event, backend)
        if Self.isTerminal(event) {
            self.active = nil
        }
    }

    private func forwardShared(_ event: TTSPlaybackEvent) {
        guard let active, active.usesSharedPlayer, event.sessionID == active.sessionID else { return }
        if case .scheduled = event {
            forwardScheduledOnce(event, backend: active.backend)
            return
        }
        eventHandler?(event, active.backend)
        if Self.isTerminal(event) {
            self.active = nil
        }
    }

    private func forwardScheduledOnce(_ event: TTSPlaybackEvent, backend: any TextToSpeechBackend) {
        guard case let .scheduled(sessionID) = event else { return }
        guard scheduledSessionID != sessionID else { return }
        scheduledSessionID = sessionID
        eventHandler?(event, backend)
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
