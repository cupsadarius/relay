import AVFoundation

/// Watches one `AVAudioEngine` for `AVAudioEngineConfigurationChange` (output or input device
/// switched, sample rate changed, headphones unplugged). AVFoundation stops the engine when this
/// fires, and every graph built against the old format is dead. Owners must fail the session
/// instead of waiting on callbacks that will never come.
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
