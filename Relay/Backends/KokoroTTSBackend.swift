import FluidAudio
import Foundation

/// On-device text-to-speech backend built on FluidAudio's Kokoro neural model. Fully offline once
/// its model is downloaded. It is a pure audio producer: `makeAudioSource` phonemizes the full
/// text, chunks it into phoneme-safe segments, and returns a `KokoroTTSAudioSource` that
/// synthesizes them sequentially. `TTSRouter` drives the shared `StreamingAudioPlayer` with that
/// source; the backend owns no speakers or playback events.
@MainActor
final class KokoroTTSBackend: TextToSpeechBackend {
    let id = "kokoro"
    let displayName = "Kokoro"

    private let engine: any KokoroEngine

    init(engine: any KokoroEngine = FluidAudioKokoroEngine()) {
        self.engine = engine
    }

    func availability() async -> BackendAvailability {
        await engine.modelsArePresent() ? .available : .modelNotDownloaded
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
        // The shared rate slider is on Apple's 0...1 scale (default 0.5); Kokoro's voiceSpeed uses
        // 1.0 = normal. This mapping lines up the shared default: 0.5 -> 1.0.
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
