import AVFoundation
import Foundation

/// Production `AudioOutputNode`: one `AVAudioPlayerNode` connected to the main mixer at the mixer's
/// own output format, so the realtime render loop never resamples (every incoming frame is
/// converted to `outputFormat` up front, off the render thread).
@MainActor
final class AVEngineOutputNode: AudioOutputNode {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let outputFormat: AVAudioFormat
    var onConfigurationChange: (@MainActor () -> Void)?
    private var configurationObserver: AudioEngineConfigurationObserver?

    init(notificationCenter: NotificationCenter = .default) {
        engine.attach(playerNode)
        outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        configurationObserver = AudioEngineConfigurationObserver(engine: engine, center: notificationCenter) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let current = self.engine.mainMixerNode.outputFormat(forBus: 0)
                guard
                    AudioEngineRouteChangeDecision.isDisruptive(
                        isEngineRunning: self.engine.isRunning,
                        installedSampleRate: self.outputFormat.sampleRate,
                        installedChannelCount: self.outputFormat.channelCount,
                        currentSampleRate: current.sampleRate,
                        currentChannelCount: current.channelCount
                    )
                else {
                    // Ignore spurious posts where the engine keeps running with the same format:
                    // AVFoundation stops the engine on a real route change, so `outputFormat`
                    // (fixed at connect time) still matches what the mixer actually produces, and
                    // already-scheduled and future buffers remain valid. Failing here would end
                    // healthy playback on every such spurious post.
                    return
                }
                self.onConfigurationChange?()
            }
        }
    }

    func start() throws { try engine.start() }
    func play() { playerNode.play() }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, onPlayed: @escaping @Sendable @MainActor () -> Void) {
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in onPlayed() }
        }
    }
}
