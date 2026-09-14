import AVFoundation

@MainActor
final class AppleTTSBackend: TextToSpeechBackend {
    let id = "apple-tts"
    let displayName = "Apple System Voice"
    let capabilities = TTSCapabilities([
        .voiceSelection,
        .pauseResume,
        .fullyOffline,
    ])

    private let synthesizer = AVSpeechSynthesizer()

    func availability() async -> BackendAvailability {
        .available
    }

    func speak(text: String, options: TTSOptions) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = options.rate

        if let identifier = options.voiceIdentifier {
            guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
                throw SpeechBackendError.invalidInput
            }
            utterance.voice = voice
        }

        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }
}
