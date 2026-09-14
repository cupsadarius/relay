import AVFoundation
import Foundation

/// Seam over `AVSpeechSynthesizer` so tests can drive playback lifecycle
/// without speaking through the real system voice.
@MainActor
protocol AppleSpeechSynthesizing: AnyObject {
    /// Must be held weakly by conforming types, matching
    /// `AVSpeechSynthesizer`'s own delegate property, so a delegate that
    /// owns its synthesizer (like `AppleTTSBackend`) does not retain-cycle.
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: AppleSpeechSynthesizing {}

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
    /// Retains the utterance alongside its session so the `ObjectIdentifier`
    /// key cannot be recycled by a deallocated-then-reallocated utterance
    /// while it is still tracked.
    private var sessionsByUtterance: [ObjectIdentifier: (utterance: AVSpeechUtterance, session: UUID)] = [:]

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

        sessionsByUtterance[ObjectIdentifier(utterance)] = (utterance, sessionID)
        // Emitted before handing off to the synthesizer so ordering holds
        // even if a delegate callback were ever delivered synchronously.
        playbackEventHandler?(.scheduled(sessionID: sessionID))
        synthesizer.speak(utterance)
    }

    func stop() {
        // Clear tracked utterances before stopping so a didCancel delivered
        // for the utterance being stopped cannot look up (and re-emit for)
        // a session we've already abandoned.
        sessionsByUtterance.removeAll()
        _ = synthesizer.stopSpeaking(at: .immediate)
    }

    func pause() {
        _ = synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        _ = synthesizer.continueSpeaking()
    }

    private func session(for utteranceID: ObjectIdentifier) -> UUID? {
        sessionsByUtterance[utteranceID]?.session
    }

    /// Removes and returns the session tracked for `utteranceID`. Called on
    /// a terminal delegate event (finish/cancel) so the map does not grow
    /// unbounded across a long-running session.
    private func endSession(for utteranceID: ObjectIdentifier) -> UUID? {
        sessionsByUtterance.removeValue(forKey: utteranceID)?.session
    }

    /// AVSpeechSynthesizer delivers delegate callbacks on the main thread
    /// today, but `AVSpeechSynthesizerDelegate` is `NS_SWIFT_SENDABLE` and
    /// the framework documents no guarantee about which thread delivers
    /// them. Assume main-actor isolation when we're already there (the
    /// common case); otherwise hop instead of trapping.
    nonisolated private func onMainActor(_ body: @escaping @MainActor (AppleTTSBackend) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body(self)
            }
        } else {
            Task { @MainActor in
                body(self)
            }
        }
    }
}

extension AppleTTSBackend: AVSpeechSynthesizerDelegate {
    // `AVSpeechUtterance` is not Sendable, so only its (Sendable) identity
    // crosses into the isolated closure.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        onMainActor { backend in
            guard let sessionID = backend.session(for: utteranceID) else { return }
            backend.playbackEventHandler?(.started(sessionID: sessionID))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        onMainActor { backend in
            guard let sessionID = backend.endSession(for: utteranceID) else { return }
            backend.playbackEventHandler?(.finished(sessionID: sessionID))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        onMainActor { backend in
            guard let sessionID = backend.endSession(for: utteranceID) else { return }
            backend.playbackEventHandler?(.cancelled(sessionID: sessionID))
        }
    }
}
