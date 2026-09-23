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

    init(engine: any KokoroEngine) {
        self.engine = engine
    }

    /// Kokoro `voiceSpeed` range Relay drives: the shared slider range
    /// (`AppSettings.validTTSRateRange`, 0.1...1.0) mapped through `rate / 0.5`, so 0.5 (the
    /// shared default) maps to 1.0 (normal speed).
    nonisolated static let speedRange: ClosedRange<Float> = 0.2...2.0

    nonisolated static func speed(forRate rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(max(rate / 0.5, speedRange.lowerBound), speedRange.upperBound)
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
        let speed = Self.speed(forRate: options.rate)
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
