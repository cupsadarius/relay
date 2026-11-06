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

    /// A plain description of a disruptive change, for the failed recording step: device names
    /// and formats only.
    static func report(
        isEngineRunning: Bool,
        installedSampleRate: Double,
        installedChannelCount: AVAudioChannelCount,
        currentSampleRate: Double,
        currentChannelCount: AVAudioChannelCount,
        inputDevice: String?,
        defaultInput: String?,
        defaultOutput: String?
    ) -> String {
        func rate(_ hertz: Double) -> String { String(format: "%g kHz", hertz / 1_000) }
        return "The audio input device changed: engine \(isEngineRunning ? "running" : "stopped"); "
            + "input \(rate(installedSampleRate)) \(installedChannelCount) ch → \(rate(currentSampleRate)) \(currentChannelCount) ch "
            + "on \(inputDevice ?? "unknown device"); default in \(defaultInput ?? "unknown"), out \(defaultOutput ?? "unknown")."
    }
}
