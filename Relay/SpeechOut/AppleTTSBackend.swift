import AVFoundation
import Foundation

/// Seam over `AVSpeechSynthesizer` so tests can drive generated-audio output without speaking
/// through the real system voice.
@MainActor
protocol AppleSpeechSynthesizing: AnyObject {
    /// Must be held weakly by conforming types, matching `AVSpeechSynthesizer`'s own delegate
    /// property.
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func write(_ utterance: AVSpeechUtterance, toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: AppleSpeechSynthesizing {}

/// Apple's on-device TTS backend as a pure audio producer. `makeAudioSource` builds an
/// `AppleTTSAudioSource` over `AVSpeechSynthesizer.write`; `TTSRouter` drives the shared
/// `StreamingAudioPlayer` with it. The backend owns no speakers, pause/resume, or playback events.
@MainActor
final class AppleTTSBackend: TextToSpeechBackend {
    let id = "apple-tts"
    let displayName = "Apple System Voice"
    let capabilities = TTSCapabilities([
        .voiceSelection,
        .fullyOffline,
    ])

    /// Builds a fresh synthesizer per `makeAudioSource` call so each speech attempt's Apple
    /// callbacks are isolated - a cancelled attempt's late buffers cannot leak into a later one.
    private let makeSynthesizer: @MainActor () -> any AppleSpeechSynthesizing
    private let bufferConverter: any AppleSpeechBufferConverting

    init(
        makeSynthesizer: @escaping @MainActor () -> any AppleSpeechSynthesizing = { AVSpeechSynthesizer() },
        bufferConverter: any AppleSpeechBufferConverting = AVAudioPCMBufferConverter()
    ) {
        self.makeSynthesizer = makeSynthesizer
        self.bufferConverter = bufferConverter
    }

    func availability() async -> BackendAvailability {
        .available
    }

    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        if let identifier = options.voiceIdentifier, AVSpeechSynthesisVoice(identifier: identifier) == nil {
            throw SpeechBackendError.invalidInput
        }
        return AppleTTSAudioSource(
            text: text,
            rate: options.rate,
            voiceIdentifier: options.voiceIdentifier,
            synthesizer: makeSynthesizer(),
            converter: bufferConverter
        )
    }
}
