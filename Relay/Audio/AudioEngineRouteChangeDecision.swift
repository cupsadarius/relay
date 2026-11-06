import AVFoundation

/// Whether an `AVAudioEngineConfigurationChange` notification represents a route change serious
/// enough to end an in-progress capture or playback, or a spurious post that leaves the engine
/// running with the same format Relay already installed a tap or connection against. AVFoundation
/// stops the engine on a real route change, so "still running, same format" reliably means this
/// particular post did not actually invalidate anything Relay is using; failing on every post
/// regardless would end perfectly healthy sessions on the spurious ones too.
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
