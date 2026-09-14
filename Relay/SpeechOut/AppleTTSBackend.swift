import AVFoundation
import Foundation

@MainActor
final class AppleTTSBackend: NSObject, TextToSpeechBackend {
    let id = "apple-tts"
    let displayName = "Apple System Voice"
    let capabilities = TTSCapabilities([
        .voiceSelection,
        .pauseResume,
        .fullyOffline,
    ])

    private let synthesizer: any AppleSpeechSynthesizing
    private var playbackEventHandler: (@MainActor (TTSPlaybackEvent) -> Void)?
    private var sessionsByUtterance: [ObjectIdentifier: UUID] = [:]

    init(synthesizer: any AppleSpeechSynthesizing = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        self.synthesizer.delegate = self
    }

    func availability() async -> BackendAvailability {
        .available
    }

    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void) {
        playbackEventHandler = handler
    }

    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = options.rate

        if let identifier = options.voiceIdentifier {
            guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
                throw SpeechBackendError.invalidInput
            }
            utterance.voice = voice
        }

        sessionsByUtterance[ObjectIdentifier(utterance)] = sessionID
        synthesizer.speak(utterance)
        playbackEventHandler?(.scheduled(sessionID: sessionID))
    }

    func stop() {
        _ = synthesizer.stopSpeaking(at: .immediate)
    }

    func pause() {
        _ = synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        _ = synthesizer.continueSpeaking()
    }

    private func session(for utteranceID: ObjectIdentifier) -> UUID? {
        sessionsByUtterance[utteranceID]
    }

    /// Removes and returns the session tracked for `utteranceID`. Called on
    /// a terminal delegate event (finish/cancel) so the map does not grow
    /// unbounded across a long-running session.
    private func endSession(for utteranceID: ObjectIdentifier) -> UUID? {
        sessionsByUtterance.removeValue(forKey: utteranceID)
    }
}

extension AppleTTSBackend: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer delivers delegate callbacks on the main thread, so
    // it is safe to assume MainActor isolation here rather than hopping with
    // a Task (which would let late callbacks reorder relative to new speak
    // calls made on the actor). `AVSpeechUtterance` is not Sendable, so only
    // its (Sendable) identity crosses into the isolated closure.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let sessionID = self.session(for: utteranceID) else { return }
            self.playbackEventHandler?(.started(sessionID: sessionID))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let sessionID = self.endSession(for: utteranceID) else { return }
            self.playbackEventHandler?(.finished(sessionID: sessionID))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let sessionID = self.endSession(for: utteranceID) else { return }
            self.playbackEventHandler?(.cancelled(sessionID: sessionID))
        }
    }
}
