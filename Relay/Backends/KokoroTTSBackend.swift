import FluidAudio
import Foundation

/// On-device text-to-speech backend built on FluidAudio's Kokoro neural model. Fully offline
/// once its model is downloaded; synthesizes to a WAV `Data` value via `KokoroEngine`, then plays
/// it through a `SynthesizedAudioPlaying` player, forwarding its lifecycle events (including
/// `.level`, which Apple's backend never emits).
@MainActor
final class KokoroTTSBackend: TextToSpeechBackend, TTSAudioSourceProducing {
    let id = "kokoro"
    let displayName = "Kokoro"
    let capabilities = TTSCapabilities([
        .fullyOffline,
        .voiceSelection,
        .pauseResume,
        .outputLevel,
    ])

    private let engine: any KokoroEngine
    private let player: any SynthesizedAudioPlaying
    private var playbackEventHandler: (@MainActor (TTSPlaybackEvent) -> Void)?

    init(
        engine: any KokoroEngine = FluidAudioKokoroEngine(),
        player: any SynthesizedAudioPlaying = SynthesizedAudioPlayer()
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

        let voice = options.kokoroVoice ?? TtsConstants.recommendedVoice
        let speed = options.rate / 0.5
        do {
            let phonemes = try await engine.phonemes(for: text)
            let chunks = KokoroPhonemeChunker(
                preferredTarget: 480,
                hardMaximum: KokoroAneConstants.maxPhonemeLength
            ).chunks(from: phonemes)
            return KokoroTTSAudioSource(
                engine: engine,
                chunks: chunks,
                voice: voice,
                speed: speed
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapEngineError(error)
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

        let voice = options.kokoroVoice ?? TtsConstants.recommendedVoice
        // The shared rate slider is on Apple's 0...1 scale (default 0.5); Kokoro's voiceSpeed
        // uses 1.0 = normal. This mapping lines up the shared default: 0.5 -> 1.0.
        let speed = options.rate / 0.5

        let wav: Data
        do {
            wav = try await engine.synthesize(text: text, voice: voice, speed: speed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // See the load-failure path above: the router owns `.failed`, not the backend.
            throw SpeechBackendError.inferenceFailed("Kokoro synthesis failed")
        }

        do {
            // `startPlayback` returns as soon as playback has started - it only throws when
            // playback never started at all (e.g. malformed WAV data), so this catch can never
            // fire after `.started` was already emitted. A failure once already playing is
            // reported by the player itself as a `.failed` playback event, not by throwing here.
            try await player.startPlayback(wav, sessionID: sessionID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // See the load-failure path above: the router owns `.failed`, not the backend.
            throw SpeechBackendError.inferenceFailed("Kokoro playback failed")
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
        case KokoroEngineError.modelsNotDownloaded:
            .modelNotDownloaded
        case KokoroEngineError.loadFailed:
            .initializationFailed("Kokoro model load failed")
        case KokoroEngineError.synthesisFailed,
             KokoroEngineError.textTooLong,
             KokoroEngineError.acousticFramesTooLong:
            .inferenceFailed("Kokoro synthesis failed")
        default:
            .initializationFailed("Kokoro model load failed")
        }
    }
}
