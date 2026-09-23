import FluidAudio
import Foundation

/// On-device text-to-speech backend built on FluidAudio's PocketTTS flow-matching model. Fully
/// offline once its model is downloaded. It is a pure audio producer: `makeAudioSource` starts the
/// engine's native Float32 stream and wraps it in a `PocketTTSAudioSource`. `TTSRouter` drives the
/// shared `StreamingAudioPlayer` with that source, so playback starts within a fraction of a second
/// of the first frame. Unlike Kokoro, PocketTTS has no speed parameter, so the shared rate slider
/// (`options.rate`) is ignored here.
@MainActor
final class PocketTTSBackend: TextToSpeechBackend {
    let id = "pocket-tts"
    let displayName = "PocketTTS"

    private let engine: any PocketTTSEngine

    init(engine: any PocketTTSEngine = FluidAudioPocketTTSEngine()) {
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
