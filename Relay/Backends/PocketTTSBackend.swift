import FluidAudio
import Foundation

/// On-device text-to-speech backend built on FluidAudio's PocketTTS flow-matching model. Fully
/// offline once its model is downloaded. It is a pure audio producer: `makeAudioSource` starts the
/// session's native Float32 stream and wraps it in a `PocketTTSAudioSource`. `TTSRouter` drives the
/// shared `StreamingAudioPlayer` with that source, so playback starts within a fraction of a second
/// of the first frame. Unlike Kokoro, PocketTTS has no speed parameter, so the shared rate slider
/// (`options.rate`) is ignored here.
@MainActor
final class PocketTTSBackend: TextToSpeechBackend {
    let id = BackendID.pocketTTS

    private let model: PocketTTSModel

    init(model: PocketTTSModel) {
        self.model = model
    }

    func availability() async -> BackendAvailability {
        await model.modelsArePresent() ? .available : .modelNotDownloaded
    }

    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        let session: any PocketTTSModelSession
        do {
            session = try await model.load()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapModelError(error)
        }

        let voice = options.voiceByBackend[id] ?? PocketTtsConstants.defaultVoice
        do {
            let stream = try await session.synthesizeStream(text: text, voice: voice)
            return PocketTTSAudioSource.make(
                stream: stream,
                sampleRate: Double(PocketTtsConstants.audioSampleRate)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechBackendError.inferenceFailed("PocketTTS synthesis failed")
        }
    }

    private static func mapModelError(_ error: Error) -> SpeechBackendError {
        switch error {
        case PocketTTSModelError.modelsNotDownloaded:
            .modelNotDownloaded
        default:
            .initializationFailed("PocketTTS model load failed")
        }
    }
}
