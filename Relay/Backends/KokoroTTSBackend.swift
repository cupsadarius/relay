import FluidAudio
import Foundation

/// On-device text-to-speech backend built on FluidAudio's Kokoro neural model. Fully offline once
/// its model is downloaded. It is a pure audio producer: `makeAudioSource` phonemizes the full
/// text, chunks it into phoneme-safe segments, and returns a `KokoroTTSAudioSource` that
/// synthesizes them sequentially. `TTSRouter` drives the shared `StreamingAudioPlayer` with that
/// source; the backend owns no speakers or playback events.
@MainActor
final class KokoroTTSBackend: TextToSpeechBackend {
    let id = BackendID.kokoro

    private let model: KokoroModel

    init(model: KokoroModel) {
        self.model = model
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
        await model.modelsArePresent() ? .available : .modelNotDownloaded
    }

    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        let session: any KokoroModelSession
        do {
            session = try await model.load()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapEngineError(error)
        }

        let voice = options.voiceByBackend[id] ?? TtsConstants.recommendedVoice
        let speed = Self.speed(forRate: options.rate)
        do {
            let phonemes = try await session.phonemes(for: text)
            let chunks = KokoroPhonemeChunker(
                preferredTarget: 480,
                hardMaximum: KokoroAneConstants.maxPhonemeLength
            ).chunks(from: phonemes)
            return KokoroTTSAudioSource.make(
                session: session,
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
        case KokoroEngineError.modelsNotDownloaded:
            .modelNotDownloaded
        case KokoroEngineError.synthesisFailed,
            KokoroEngineError.textTooLong,
            KokoroEngineError.acousticFramesTooLong:
            .inferenceFailed("Kokoro synthesis failed")
        default:
            .initializationFailed("Kokoro model load failed")
        }
    }
}
