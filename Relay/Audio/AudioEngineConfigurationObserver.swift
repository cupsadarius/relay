import AVFoundation

/// Watches one `AVAudioEngine` for `AVAudioEngineConfigurationChange` (output or input device
/// switched, sample rate changed, headphones unplugged). AVFoundation stops the engine on a real
/// route change, and every graph built against the old format is dead, so owners generally must
/// fail the session instead of waiting on callbacks that will never come. Some posts are spurious
/// (the notification fires with the engine still running at the same format); `onChange` delivers
/// every post as-is and leaves filtering those out to the owner -- see
/// `AudioEngineRouteChangeDecision`, which `MicrophoneCapture` and `StreamingAudioPlayer` both use
/// to ignore that case rather than ending a perfectly healthy session.
///
/// Observation ends when the observer is released. `center` is injectable so tests can post the
/// notification without a real audio device.
final class AudioEngineConfigurationObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    /// - Parameter engine: the engine whose notifications are delivered, matched by identity.
    ///   `onChange` runs on the posting thread.
    init(engine: AnyObject, center: NotificationCenter = .default, onChange: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            onChange()
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
