import AVFoundation

/// Whether an `AVAudioEngineConfigurationChange` notification represents a route change serious
/// enough to end an in-progress capture or playback, or a benign renegotiation that leaves the
/// engine running and its format unchanged. Some route events -- e.g. AirPods switching their
/// Bluetooth profile between A2DP and HFP right as a recording starts -- post this notification
/// without actually invalidating the format Relay already installed a tap or connection with;
/// failing on every post would end perfectly healthy sessions.
///
/// Pure, so both `MicrophoneCapture` (input) and `StreamingAudioPlayer` (output) can test their
/// route-change filtering without a real `AVAudioEngine`.
enum AudioEngineRouteChangeDecision {
    static func isDisruptive(
        isEngineRunning: Bool,
        installedSampleRate: Double,
        installedChannelCount: AVAudioChannelCount,
        currentSampleRate: Double,
        currentChannelCount: AVAudioChannelCount
    ) -> Bool {
        guard isEngineRunning else { return true }
        return installedSampleRate != currentSampleRate || installedChannelCount != currentChannelCount
    }
}
