import FluidAudio
import Foundation

/// On-device text-to-speech backend built on FluidAudio's PocketTTS flow-matching model. Fully
/// offline once its model is downloaded; streams synthesized audio frames via `PocketTTSEngine`'s
/// `synthesizeStream(text:voice:)` and plays them through a `StreamingAudioPlaying` player as they
/// arrive, so playback starts within a fraction of a second instead of waiting for the whole
/// utterance to synthesize. Forwards the player's lifecycle events (including `.level`, which
/// Apple's backend never emits). Unlike `KokoroTTSBackend`, PocketTTS has no speed parameter, so
/// the shared rate slider (`options.rate`) is ignored here.
@MainActor
final class PocketTTSBackend: TextToSpeechBackend, TTSAudioSourceProducing {
    let id = "pocket-tts"
    let displayName = "PocketTTS"
    let capabilities = TTSCapabilities([
        .fullyOffline,
        .voiceSelection,
        .pauseResume,
        .outputLevel,
        .streaming,
    ])

    private let engine: any PocketTTSEngine
    private let player: any StreamingAudioPlaying
    private var playbackEventHandler: (@MainActor (TTSPlaybackEvent) -> Void)?

    init(
        engine: any PocketTTSEngine = FluidAudioPocketTTSEngine(),
        player: any StreamingAudioPlaying = StreamingAudioPlayer()
    ) {
        self.engine = engine
        self.player = player
        self.player.onEvent = { [weak self] event in self?.playbackEventHandler?(event) }
    }

    func availability() async -> BackendAvailability {
        await engine.modelsArePresent() ? .available : .modelNotDownloaded
    }

    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void) {
        playbackEventHandler = handler
    }

    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        do {
            try await engine.load(allowDownload: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapEngineError(error)
        }

        let voice = options.pocketVoice ?? PocketTtsConstants.defaultVoice
        do {
            let stream = try await engine.synthesizeStream(text: text, voice: voice)
            return PocketTTSAudioSource(
                stream: stream,
                sampleRate: Double(PocketTtsConstants.audioSampleRate)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechBackendError.inferenceFailed("PocketTTS synthesis failed")
        }
    }

    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
        do {
            try await engine.load(allowDownload: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Don't emit `.failed` here: `TTSRouter` centralizes that event and emits it only
            // once every backend has been exhausted. Emitting it from the backend would surface
            // a failure even when the router successfully falls back to another backend.
            throw Self.mapEngineError(error)
        }

        let voice = options.pocketVoice ?? PocketTtsConstants.defaultVoice

        let stream: AsyncThrowingStream<[Float], Error>
        do {
            stream = try await engine.synthesizeStream(text: text, voice: voice)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // See the load-failure path above: the router owns `.failed`, not the backend.
            throw SpeechBackendError.inferenceFailed("PocketTTS synthesis failed")
        }

        do {
            // `startPlayback` returns as soon as playback has actually started (after
            // prebuffering) - it only throws when playback never started at all, including a
            // source-stream failure that surfaces before then. A failure once already playing is
            // reported by the player itself as a `.failed` playback event, not by throwing here.
            try await player.startPlayback(stream, sampleRate: Double(PocketTtsConstants.audioSampleRate), sessionID: sessionID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // See the load-failure path above: the router owns `.failed`, not the backend.
            throw SpeechBackendError.inferenceFailed("PocketTTS playback failed")
        }
    }

    func stop() {
        player.stop()
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.resume()
    }

    private static func mapEngineError(_ error: Error) -> SpeechBackendError {
        switch error {
        case let error as SpeechBackendError:
            error
        case PocketTTSEngineError.modelsNotDownloaded:
            .modelNotDownloaded
        case PocketTTSEngineError.loadFailed:
            .initializationFailed("PocketTTS model load failed")
        case PocketTTSEngineError.synthesisFailed:
            .inferenceFailed("PocketTTS synthesis failed")
        default:
            .initializationFailed("PocketTTS model load failed")
        }
    }
}

extension PocketTTSBackend: SpeechModelDownloading {
    /// Downloads PocketTTS's model, bypassing `speak`'s lazy, download-refusing
    /// `load(allowDownload: false)` path. Used only by the Settings "Download" action - never
    /// called from the speak path.
    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await engine.load(allowDownload: true, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapEngineError(error)
        }
    }
}
